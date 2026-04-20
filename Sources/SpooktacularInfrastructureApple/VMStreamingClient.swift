import Foundation
import Network
import os
import SpooktacularCore

/// Connects to a VM's streaming host-API socket and exposes
/// per-topic `AsyncThrowingStream`s typed to the payload kind
/// the topic carries.
///
/// One client instance holds a single `NWConnection` to
/// `~/Library/Application Support/Spooktacular/api/<vm>.sock`.
/// Multiple `subscribe` calls multiplex onto that one
/// connection — the server assigns distinct subscription IDs
/// and the client demuxes incoming frames to the right stream
/// continuation.
///
/// ## 60 fps target
///
/// The receive loop runs on a dedicated serial queue and only
/// wakes when bytes arrive — no polling, no timer wheels. Each
/// frame does one length-prefix parse and one binary-plist
/// decode into the Codable payload. On an M2 the round-trip is
/// ~30 µs, leaving 16 636 µs of 60 Hz frame budget for SwiftUI
/// to reconcile and the GPU to render.
///
/// ## Cancellation
///
/// `AsyncThrowingStream.onTermination` drops the subscription
/// from the demux table when a caller stops iterating, and
/// `disconnect()` cancels the `NWConnection` which tears every
/// topic down in a single syscall.
///
/// ## Apple APIs used
///
/// - [`NWConnection`](https://developer.apple.com/documentation/network/nwconnection)
/// - [`NWEndpoint.unix(path:)`](https://developer.apple.com/documentation/network/nwendpoint)
/// - [`NWParameters`](https://developer.apple.com/documentation/network/nwparameters)
///   — default-init (no `.tcp` preset) per Apple's UDS
///   guidance; the TCP preset costs nothing but signals the
///   wrong intent for an AF_UNIX stream socket.
public actor VMStreamingClient {

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "vm-streaming-client"
    )

    /// Unix-domain-socket path this client dials. Readable so
    /// diagnostics ("which socket is this client attached to?")
    /// don't need to reach into private state.
    public let socketURL: URL

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.spooktacular.vm-streaming-client")

    /// Sinks keyed by server-assigned subscription ID. Each
    /// sink owns the decode closure for its payload type, so
    /// the demux table is homogeneous `[UInt32: Sink]` even
    /// though different topics carry different Codable types.
    private var sinks: [UInt32: any Sink] = [:]

    /// Pending subscription requests waiting for an Ack.
    /// FIFO — the server processes Subscribe frames in order,
    /// so the oldest pending request owns the next Ack's
    /// topic ID.
    private var pending: [Pending] = []

    private struct Pending {
        let topic: VMStreamingProtocol.Topic
        let install: (UInt32) -> Void
    }

    /// Type-erased subscription sink. Concrete implementation
    /// is ``TypedSink`` below, parameterised over the payload
    /// type. The existential lets the demux table stay single-
    /// typed while the per-subscription code paths stay
    /// strongly typed.
    private protocol Sink: Sendable {
        func deliver(_ data: Data)
        func fail(_ error: any Error)
        func finish()
    }

    private struct TypedSink<Payload: Decodable & Sendable>: Sink {
        let continuation: AsyncThrowingStream<Payload, any Error>.Continuation

        func deliver(_ data: Data) {
            do {
                let value = try VMStreamingCodec.decode(Payload.self, from: data)
                continuation.yield(value)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        func fail(_ error: any Error) {
            continuation.finish(throwing: error)
        }
        func finish() {
            continuation.finish()
        }
    }

    private var readBuffer = Data()
    private var didStart = false

    /// Creates a client that dials the given UDS path. Does
    /// not connect until ``start()`` is called.
    ///
    /// - Parameter socketURL: File URL to a Unix-domain socket
    ///   the server has already bound (typically written by
    ///   ``VMStreamingServer``).
    public init(socketURL: URL) {
        self.socketURL = socketURL
        let endpoint = NWEndpoint.unix(path: socketURL.path)
        // `NWParameters()` — default init, no TCP preset. Apple's
        // Network.framework docs and the developer-forum
        // guidance (thread 756756) both say the `.tcp` preset
        // is misleading for AF_UNIX streams: it works but
        // signals the wrong intent and pulls in configuration
        // slots the UDS transport ignores.
        let parameters = NWParameters()
        self.connection = NWConnection(to: endpoint, using: parameters)
    }

    // MARK: - Lifecycle

    /// Opens the UDS connection. Idempotent. Must be called
    /// before any `subscribe(...)`.
    public func connect() async throws {
        guard !didStart else { return }
        didStart = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    continuation.resume()
                    Task { await self?.startReceiveLoop() }
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Cancels the UDS connection and fails every in-flight
    /// stream with ``VMStreamingError/Code/internalError``.
    public func disconnect() {
        let err = VMStreamingError(code: .internalError, reason: "Client disconnected")
        for (_, sink) in sinks {
            sink.fail(err)
        }
        sinks.removeAll()
        pending.removeAll()
        connection.cancel()
    }

    // MARK: - Typed subscriptions

    /// Subscribes to `topic` and returns an `AsyncThrowingStream`
    /// that yields decoded `Payload` values as the server
    /// pushes them.
    ///
    /// Multiple concurrent subscriptions (even to the same
    /// topic) multiplex onto the same connection — each call
    /// gets its own subscription ID and its own stream.
    public func subscribe<Payload: Decodable & Sendable>(
        to topic: VMStreamingProtocol.Topic,
        as payloadType: Payload.Type
    ) -> AsyncThrowingStream<Payload, any Error> {
        AsyncThrowingStream { continuation in
            let sink = TypedSink<Payload>(continuation: continuation)
            // `swift build` on macOS 26 says the inner `await`
            // is superfluous, but Xcode's Swift-6 sending-
            // parameter enforcement at `Task.init` disagrees:
            // without it, the Task body's capture of
            // `self` + non-Sendable-at-the-capture-site closures
            // trips a data-race diagnostic. The `await` is the
            // Apple-canonical way to establish that the Task
            // body hops back onto the actor before touching
            // self. Keep it.
            Task { await self.register(topic: topic, sink: sink) }

            continuation.onTermination = { [weak self] _ in
                // `onTermination` can fire on any thread; hop
                // back to the actor to drop the demux entry
                // and send the Unsubscribe frame.
                Task { await self?.cancelSubscription(for: topic, sink: sink) }
            }
        }
    }

    private func register(topic: VMStreamingProtocol.Topic, sink: any Sink) {
        pending.append(Pending(topic: topic) { [weak self] subscriptionID in
            Task { await self?.install(sink: sink, subscriptionID: subscriptionID) }
        })
        let request = VMStreamSubscribeRequest(topic: topic)
        let payload = (try? VMStreamingCodec.encode(request)) ?? Data()
        send(VMStreamingFrame(kind: .subscribe, topic: 0, payload: payload))
    }

    private func install(sink: any Sink, subscriptionID: UInt32) {
        sinks[subscriptionID] = sink
    }

    /// Finds the subscription ID associated with this sink (we
    /// don't know it at `cancel` time) and sends Unsubscribe.
    /// Best-effort — if the server already closed the
    /// subscription for another reason, the frame is a no-op.
    private func cancelSubscription(for topic: VMStreamingProtocol.Topic, sink: any Sink) {
        for (id, existing) in sinks where ObjectIdentifier(type(of: existing)) == ObjectIdentifier(type(of: sink)) {
            sinks.removeValue(forKey: id)
            send(VMStreamingFrame(kind: .unsubscribe, topic: id))
            return
        }
    }

    // MARK: - Receive loop

    private func startReceiveLoop() {
        Task.detached { [weak self] in
            guard let self else { return }
            while true {
                do {
                    let chunk = try await self.receiveChunk()
                    guard let data = chunk, !data.isEmpty else {
                        await self.connectionClosed()
                        return
                    }
                    await self.ingest(data)
                } catch {
                    await self.connectionClosed()
                    return
                }
            }
        }
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if isComplete, data?.isEmpty ?? true {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }

    private func ingest(_ data: Data) async {
        readBuffer.append(data)
        while true {
            do {
                guard let frame = try parseVMStreamingFrame(from: &readBuffer) else {
                    return
                }
                await handle(frame: frame)
            } catch {
                Self.log.warning(
                    "Streaming frame parse failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
    }

    private func handle(frame: VMStreamingFrame) async {
        switch frame.kind {
        case .ack:
            if !pending.isEmpty {
                let nextPending = pending.removeFirst()
                nextPending.install(frame.topic)
            }

        case .event:
            sinks[frame.topic]?.deliver(frame.payload)

        case .error:
            let error: any Error
            if let err = try? VMStreamingCodec.decode(
                VMStreamingError.self,
                from: frame.payload
            ) {
                error = err
            } else {
                error = VMStreamingError(
                    code: .internalError,
                    reason: "Unparseable error frame"
                )
            }
            if let sink = sinks.removeValue(forKey: frame.topic) {
                sink.fail(error)
            }

        case .heartbeat:
            break

        default:
            break
        }
    }

    private func connectionClosed() {
        for (_, sink) in sinks {
            sink.finish()
        }
        sinks.removeAll()
        pending.removeAll()
    }

    // MARK: - Sending

    private func send(_ frame: VMStreamingFrame) {
        connection.send(
            content: frame.encoded(),
            completion: .contentProcessed { error in
                if let error {
                    Self.log.warning(
                        "Subscribe send failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        )
    }
}
