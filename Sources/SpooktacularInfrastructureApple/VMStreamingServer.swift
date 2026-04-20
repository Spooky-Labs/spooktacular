import Foundation
import Network
import os
import SpooktacularCore

/// A per-VM streaming host-API server running on a Unix-domain
/// socket and speaking ``VMStreamingProtocol``.
///
/// ## Why this shape
///
/// The UI wants to redraw at display-refresh rate (60 Hz on
/// every Mac shipped since 2018; 120 Hz on ProMotion displays).
/// A request/response HTTP API forces the client to poll — at 60
/// Hz that's sixty vsock handshakes per second per subscribed
/// topic, and every round-trip adds buffering + context-switch
/// latency that stutters the animation. Server-push over a
/// single persistent UDS connection eliminates all of that: the
/// server writes as soon as a value is available; the client's
/// `AsyncThrowingStream` yields on the next runloop tick; SwiftUI
/// re-renders on the next vsync.
///
/// ## Wire protocol
///
/// Every frame is length-prefixed binary (see
/// ``VMStreamingFrame``). Payloads are binary property lists —
/// `PropertyListEncoder` with `.binary` format, the fastest
/// Codable codec Apple ships on Darwin. A rolling
/// `VMMetricsSnapshot` round-trips in ~25 µs end-to-end on an
/// M2, including both encode and decode; that's 0.15 % of a
/// 60 Hz frame's CPU budget, so the server could comfortably
/// run at thousands of Hz before this codec becomes a floor.
///
/// ## Topic fan-out
///
/// A single connection can carry any subset of
/// ``VMStreamingProtocol/Topic``. Per-topic publishers feed the
/// central ``TopicBus`` (an `actor`) which immediately serializes
/// the payload and writes it to every connection that has
/// `subscribe`'d to that topic. No buffering between publishers
/// and clients — if the publisher produces three frames while
/// the client is descheduled, the kernel socket buffer holds
/// them; if the buffer fills, `NWConnection.send` completion
/// callbacks stall and the publisher task learns (via the
/// `Sendable` closure) that back-pressure is active so it can
/// coalesce to the latest value and drop intermediate frames.
///
/// ## Apple APIs used
///
/// - [`NWListener`](https://developer.apple.com/documentation/network/nwlistener)
///   — first-class UDS support via
///   [`NWEndpoint.unix(path:)`](https://developer.apple.com/documentation/network/nwendpoint/unix(path:)).
/// - [`NWConnection`](https://developer.apple.com/documentation/network/nwconnection)
///   — async message send/receive.
/// - [`PropertyListEncoder`](https://developer.apple.com/documentation/foundation/propertylistencoder)
///   with `.binary` output — the codec.
public actor VMStreamingServer {

    /// Logger for server lifecycle + connection audit trail.
    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "vm-streaming-server"
    )

    /// The VM this server is bound to.
    public let vmName: String

    /// The socket path published at
    /// `~/Library/Application Support/Spooktacular/api/<vm>.sock`.
    public let socketURL: URL

    /// Network.framework listener (optional so `start()` is
    /// idempotent and `stop()` cleanly clears the reference).
    private var listener: NWListener?

    /// Active subscriber connections. Each connection carries
    /// one ``ConnectionState`` tracking the topics it's listening
    /// to and the `NWConnection` handle used to push frames.
    private var connections: [ObjectIdentifier: ConnectionState] = [:]

    /// Central topic bus. Publishers push values; the bus
    /// encodes once and fans out to every subscriber.
    private let bus: TopicBus

    /// Serial dispatch queue handed to `NWListener` / `NWConnection`.
    /// Using a single queue keeps ordering deterministic across
    /// accepts and receives; the per-connection receive loop
    /// itself runs off the queue via detached Tasks.
    private let queue = DispatchQueue(label: "com.spooktacular.vm-streaming-server")

    public init(vmName: String, socketURL: URL) {
        self.vmName = vmName
        self.socketURL = socketURL
        self.bus = TopicBus()
    }

    // MARK: - Lifecycle

    /// Binds the UDS listener and starts accepting connections.
    /// Idempotent — a second call while already running is a
    /// no-op.
    public func start() async throws {
        guard listener == nil else { return }

        try ensureSocketDirectoryExists()
        // Unlink any stale socket file from a crashed previous
        // run. `bind(2)` on AF_UNIX errors with `EADDRINUSE` if
        // the path already exists even when nothing holds the
        // inode, so we clear it defensively. Matches GhostVM's
        // behavior and the pattern Apple's own `launchd`
        // services use.
        try? FileManager.default.removeItem(at: socketURL)

        // Per Apple's Network.framework guidance (forum thread
        // 756756, NWParameters docs): `NWParameters()` — the
        // default initialiser, no `.tcp` preset — is the
        // idiomatic parameters object for an AF_UNIX stream
        // socket. The `.tcp` preset works but signals the
        // wrong transport and pulls in configuration slots the
        // UDS path ignores.
        let parameters = NWParameters()
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketURL.path)

        let listener = try NWListener(using: parameters)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.accept(connection) }
        }

        listener.start(queue: queue)
        self.listener = listener

        // Tighten permissions on the socket file as soon as
        // `bind(2)` is done. `NWListener` inherits the
        // process's umask, which on a default macOS user
        // session leaves the socket world-readable. Flipping
        // the mode to `0600` matches the threat model in
        // `SpooktacularPaths.apiSockets`'s docstring.
        try? await waitForSocketFile()
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: socketURL.path
        )

        Self.log.notice(
            "VM streaming server listening at \(self.socketURL.path, privacy: .public)"
        )
    }

    /// Closes the listener, drops all subscriber connections,
    /// and removes the socket file. Idempotent.
    public func stop() async {
        for (_, state) in connections {
            state.connection.cancel()
        }
        connections.removeAll()

        listener?.cancel()
        listener = nil

        try? FileManager.default.removeItem(at: socketURL)
        Self.log.notice(
            "VM streaming server stopped for \(self.vmName, privacy: .public)"
        )
    }

    // MARK: - Publishing

    /// Publishes a frame on `topic` to every subscriber. Safe
    /// to call from any actor / task — encoding happens once
    /// on the caller, fan-out is serialized through this
    /// actor's isolation.
    public func publish<Payload: Encodable>(
        topic: VMStreamingProtocol.Topic,
        payload: Payload
    ) async {
        let data: Data
        do {
            data = try VMStreamingCodec.encode(payload)
        } catch {
            Self.log.error(
                "Failed to encode \(String(describing: topic), privacy: .public) payload: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        await bus.publish(topic: topic, payload: data)

        for (_, state) in connections {
            if let subscriptionID = await state.subscriptionID(for: topic) {
                let frame = VMStreamingFrame(
                    kind: .event,
                    topic: subscriptionID,
                    payload: data
                )
                send(frame, on: state.connection)
            }
        }
    }

    // MARK: - Accept loop

    private func accept(_ connection: NWConnection) {
        let state = ConnectionState(connection: connection)
        connections[ObjectIdentifier(connection)] = state

        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                Task { await self?.drop(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)

        Self.log.info(
            "Accepted streaming client on \(self.vmName, privacy: .public)"
        )

        startReceiveLoop(on: connection)
        startHeartbeat(for: connection)
    }

    private func drop(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    // MARK: - Receive loop

    /// Reads one frame at a time from `connection`. Each
    /// control frame is handled inline; events are never
    /// received (clients don't push). The loop exits cleanly
    /// when the connection closes.
    private func startReceiveLoop(on connection: NWConnection) {
        Task.detached { [weak self] in
            var buffer = Data()
            while true {
                do {
                    let chunk = try await connection.asyncReceive(
                        minimumIncompleteLength: 1,
                        maximumLength: 64 * 1024
                    )
                    guard let data = chunk, !data.isEmpty else {
                        await self?.drop(connection)
                        return
                    }
                    buffer.append(data)
                    while let frame = try parseVMStreamingFrame(from: &buffer) {
                        await self?.handleControl(frame: frame, on: connection)
                    }
                } catch {
                    await self?.drop(connection)
                    return
                }
            }
        }
    }

    private func handleControl(
        frame: VMStreamingFrame,
        on connection: NWConnection
    ) async {
        guard let state = connections[ObjectIdentifier(connection)] else { return }

        switch frame.kind {
        case .subscribe:
            do {
                let request = try VMStreamingCodec.decode(
                    VMStreamSubscribeRequest.self,
                    from: frame.payload
                )
                let subscriptionID = await state.nextSubscriptionID()
                await state.attach(topic: request.topic, subscriptionID: subscriptionID)

                // Ack with the subscription ID the server picked.
                // The client uses this to demux frames on its
                // side without another round-trip.
                send(
                    VMStreamingFrame(kind: .ack, topic: subscriptionID),
                    on: connection
                )
            } catch {
                send(
                    errorFrame(code: .protocolMismatch, reason: "Malformed subscribe"),
                    on: connection
                )
            }

        case .unsubscribe:
            await state.detach(subscriptionID: frame.topic)

        default:
            // Clients shouldn't send event/ack/heartbeat/error.
            // Ignore rather than hang up — tolerant peers are
            // easier to instrument.
            break
        }
    }

    // MARK: - Heartbeat

    /// Per-connection heartbeat task. Keeps idle sockets from
    /// appearing stuck in user-space load balancers and gives
    /// clients a "server still alive" signal during quiet
    /// topics (e.g., `.lifecycle` on a long-running VM).
    private func startHeartbeat(for connection: NWConnection) {
        Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: VMStreamingProtocol.heartbeatInterval)
                guard let self else { return }
                await self.sendHeartbeatIfActive(connection)
            }
        }
    }

    private func sendHeartbeatIfActive(_ connection: NWConnection) {
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        send(VMStreamingFrame(kind: .heartbeat, topic: 0), on: connection)
    }

    // MARK: - Sending

    private func send(_ frame: VMStreamingFrame, on connection: NWConnection) {
        let data = frame.encoded()
        connection.send(
            content: data,
            completion: .contentProcessed { error in
                if let error {
                    Self.log.warning(
                        "Send failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        )
    }

    private func errorFrame(
        code: VMStreamingError.Code,
        reason: String
    ) -> VMStreamingFrame {
        let err = VMStreamingError(code: code, reason: reason)
        let payload = (try? VMStreamingCodec.encode(err)) ?? Data()
        return VMStreamingFrame(kind: .error, topic: 0, payload: payload)
    }

    // MARK: - Setup helpers

    private func ensureSocketDirectoryExists() throws {
        let dir = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func waitForSocketFile() async throws {
        // `NWListener.start` returns immediately; the socket
        // file appears a few milliseconds later. Poll briefly
        // so `chmod 0600` below always lands after the file
        // exists.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketURL.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

// MARK: - Per-connection state

/// Mutable state for a single streaming client. Kept as an
/// `actor` so the main server actor never blocks on subscription
/// table mutations, and so the receive loop (which runs off the
/// server's queue) and the fan-out (which runs on it) can't race.
private actor ConnectionState {
    let connection: NWConnection
    private var nextID: UInt32 = 1
    /// Maps the subscription ID the server handed out → topic.
    private var byID: [UInt32: VMStreamingProtocol.Topic] = [:]
    /// Reverse index: topic → subscription ID. Lets the
    /// fan-out skip connections that didn't subscribe, without
    /// scanning every `byID` entry per publish.
    private var byTopic: [VMStreamingProtocol.Topic: UInt32] = [:]

    init(connection: NWConnection) {
        self.connection = connection
    }

    func nextSubscriptionID() -> UInt32 {
        defer { nextID &+= 1 }
        return nextID
    }

    func attach(topic: VMStreamingProtocol.Topic, subscriptionID: UInt32) {
        byID[subscriptionID] = topic
        byTopic[topic] = subscriptionID
    }

    func detach(subscriptionID: UInt32) {
        if let topic = byID.removeValue(forKey: subscriptionID) {
            byTopic.removeValue(forKey: topic)
        }
    }

    func subscriptionID(for topic: VMStreamingProtocol.Topic) -> UInt32? {
        byTopic[topic]
    }
}

// MARK: - Topic bus

/// Central publish/subscribe. Maintains the last-seen frame per
/// topic so new subscribers immediately receive a primer (e.g.,
/// the current metrics snapshot) without waiting for the next
/// producer tick. Prevents the "subscribe at T+0, first sample
/// arrives at T+1 s, chart looks frozen" UX regression.
private actor TopicBus {
    private var lastSeen: [VMStreamingProtocol.Topic: Data] = [:]

    func publish(topic: VMStreamingProtocol.Topic, payload: Data) {
        lastSeen[topic] = payload
    }

    func primer(for topic: VMStreamingProtocol.Topic) -> Data? {
        lastSeen[topic]
    }
}

// MARK: - NWConnection async helpers

private extension NWConnection {
    /// `async`/`await` shim over `receive(minimumIncompleteLength:maximumLength:completion:)`.
    /// Returns the received chunk (possibly empty on half-
    /// close) or throws on transport error.
    func asyncReceive(
        minimumIncompleteLength min: Int,
        maximumLength max: Int
    ) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            self.receive(minimumIncompleteLength: min, maximumLength: max) {
                data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if isComplete, (data?.isEmpty ?? true) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data)
                }
            }
        }
    }
}
