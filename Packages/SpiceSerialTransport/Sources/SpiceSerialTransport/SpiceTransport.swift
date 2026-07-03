import Foundation
import Dispatch
import SpiceProtocol

/// Async, actor-isolated SPICE `vd_agent` transport.
///
/// Opens the virtio-serial device, drives a non-blocking read
/// loop via `DispatchSource.makeReadSource`, bridges inbound
/// framed messages into an `AsyncThrowingStream`, and
/// serializes outbound writes so concurrent callers can't
/// interleave bytes.
///
/// ## Usage
///
/// ```swift
/// let transport = try SpiceTransport()
/// try await transport.start()
///
/// // Receive side — runs until the transport closes.
/// Task {
///     for try await msg in await transport.messages {
///         handle(msg)
///     }
/// }
///
/// // Send side — each call frames + writes atomically.
/// try await transport.send(
///     type: .announceCapabilities,
///     payload: VDAgentAnnounceCapabilities(
///         request: false,
///         capabilities: .macGuestDefault
///     ).encode()
/// )
/// ```
///
/// ## Lifecycle
///
/// Construction opens the fd and configures termios but
/// doesn't start reading. Call ``start()`` to begin the read
/// loop (separated so tests can open the transport against a
/// pipe without a real read source). ``close()`` cancels the
/// read source, finishes the message stream, and closes the
/// fd — idempotent, safe to call from any context.
public actor SpiceTransport {

    // MARK: - State

    private let port: SpiceSerialPort
    private let readQueue: DispatchQueue
    private var readSource: (any DispatchSourceRead)?
    private var framer = SpiceFramer()
    private var continuation: AsyncThrowingStream<SpiceIncomingMessage, Error>.Continuation?
    private var started = false
    private var closedFlag = false

    /// The inbound message stream. Declared `nonisolated let`
    /// so callers can write `for try await msg in
    /// transport.messages` without an `await` on the actor —
    /// the stream value itself never mutates, only the
    /// continuation owned inside the actor does.
    public nonisolated let messages:
        AsyncThrowingStream<SpiceIncomingMessage, Error>

    // MARK: - Init

    public init(devicePath: String = SpiceSerialPort.defaultDevicePath) throws {
        self.port = try SpiceSerialPort(devicePath: devicePath)
        self.readQueue = DispatchQueue(
            label: "com.spooktacular.spice.transport.read",
            qos: .userInitiated
        )

        // `makeStream` hands us a tuple of (stream, continuation)
        // synchronously — no race between the continuation
        // being created and the read source yielding to it.
        let (stream, continuation) = AsyncThrowingStream<
            SpiceIncomingMessage, Error
        >.makeStream(
            of: SpiceIncomingMessage.self,
            throwing: Error.self,
            bufferingPolicy: .unbounded
        )
        self.messages = stream
        self.continuation = continuation
    }

    deinit {
        // Fire-and-forget close. Skip if we never started or
        // already closed — both paths are idempotent so this
        // is just for clarity.
        if let source = readSource, !source.isCancelled {
            source.cancel()
        }
        port.close()
        continuation?.finish()
    }

    // MARK: - Public API

    /// Begins the non-blocking read loop. Safe to call
    /// multiple times; only the first has effect.
    public func start() {
        guard !started, !closedFlag else { return }
        started = true

        let source = DispatchSource.makeReadSource(
            fileDescriptor: port.fileDescriptor,
            queue: readQueue
        )
        readSource = source

        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Hop back into the actor to mutate framer state
            // and yield. Can't call actor-isolated methods
            // directly from a Dispatch handler; `Task` is the
            // sanctioned bridge.
            Task { await self.handleReadable() }
        }
        source.setCancelHandler { [weak self] in
            // Can't access actor state synchronously here —
            // another Task hop.
            Task { await self?.finishStream(error: nil) }
        }
        source.resume()
    }

    /// Frames `payload` with the SPICE chunk + agent headers
    /// and writes the entire frame to the device. Serialized
    /// by the actor — concurrent callers queue.
    public func send(
        type: VDAgentMessageType,
        payload: Data
    ) throws {
        let frame = SpiceCodec.frame(type: type, payload: payload)
        try port.write(frame)
    }

    /// Tears down the transport. Idempotent.
    public func close() {
        guard !closedFlag else { return }
        closedFlag = true
        readSource?.cancel()
        readSource = nil
        port.close()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Internal

    private func handleReadable() {
        // Drain whatever's available; `read` on our fd is
        // non-blocking so we'll get `.empty` back when the
        // kernel queue runs dry.
        while !closedFlag {
            let chunk: Data
            do {
                chunk = try port.read()
            } catch SpiceSerialPortError.peerClosed {
                finishStream(error: SpiceSerialPortError.peerClosed)
                return
            } catch {
                finishStream(error: error)
                return
            }
            if chunk.isEmpty { return }

            let messages: [SpiceIncomingMessage]
            do {
                messages = try framer.ingest(chunk)
            } catch {
                finishStream(error: error)
                return
            }
            for message in messages {
                continuation?.yield(message)
            }
        }
    }

    private func finishStream(error: Error?) {
        guard !closedFlag else { return }
        closedFlag = true
        continuation?.finish(throwing: error)
        continuation = nil
        readSource?.cancel()
        readSource = nil
    }
}
