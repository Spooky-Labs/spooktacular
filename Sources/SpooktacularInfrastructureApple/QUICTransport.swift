import Foundation
import Network
import Security
import SpooktacularCore
import os

/// QUIC-backed adapter for the ``RemoteStreamServer`` port.
///
/// Application-layer callers depend on ``RemoteStreamServer``.
/// This type is one concrete adapter, wiring Apple's QUIC
/// implementation (via `Network.framework`) into that port.
/// All QUIC-specific concerns — ALPN negotiation, TLS 1.3
/// handshake, `SecIdentity` loading, `NWListener` state
/// transitions — live inside this file and never surface in
/// the port's contract.
///
/// ## Clean Architecture
///
/// - Domain (`SpooktacularCore`): declares ``RemoteStreamServer``
///   + ``RemoteStream``.  No Apple-framework imports.
/// - Infrastructure (this file): implements the port using
///   `NWListener` + `NWProtocolQUIC`.  Hides `NWConnection`
///   behind ``QUICStream``; hides `SecIdentity` behind the
///   composition-root-injected `identityLoader` closure; hides
///   ALPN behind the adapter's constructor.
/// - Composition root (CLI/GUI): constructs this adapter with
///   the transport-specific knobs (ALPN list, identity source),
///   then hands the resulting `any RemoteStreamServer` to
///   application-layer code.
///
/// ## Apple APIs used — all doc-cited
///
/// - [`NWParameters.quic(alpn:)`](https://developer.apple.com/documentation/network/nwparameters/quic(alpn:))
///   — convenience factory for QUIC parameters.  Not used here
///   directly; we take the long form via
///   [`NWParameters(quic:)`](https://developer.apple.com/documentation/network/nwparameters/init(quic:))
///   so we can customise the `securityProtocolOptions`.
/// - [`NWProtocolQUIC.Options(alpn:)`](https://developer.apple.com/documentation/network/nwprotocolquic/options/init(alpn:))
///   — `convenience init(alpn: [String])`.
/// - [`NWProtocolQUIC.Options.securityProtocolOptions`](https://developer.apple.com/documentation/network/nwprotocolquic/options/securityprotocoloptions)
///   — `var securityProtocolOptions: sec_protocol_options_t`.
/// - [`sec_identity_create`](https://developer.apple.com/documentation/security/sec_identity_create(_:))
///   — `func sec_identity_create(_ identity: SecIdentity) -> sec_identity_t?`.
///   Guarded with a typed throw — never force-unwrapped.
/// - [`sec_protocol_options_set_local_identity`](https://developer.apple.com/documentation/security/sec_protocol_options_set_local_identity(_:_:))
///   — binds the TLS handshake to a `sec_identity_t`.
/// - [`NWListener(using:on:)`](https://developer.apple.com/documentation/network/nwlistener/init(using:on:))
///   — `init(using: NWParameters, on: NWEndpoint.Port = .any) throws`.
/// - [`NWListener.newConnectionHandler`](https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler)
///   — Sendable closure invoked once per accepted connection.
/// - [`NWListener.stateUpdateHandler`](https://developer.apple.com/documentation/network/nwlistener/stateupdatehandler)
///   — Sendable closure called per listener state change.
/// - [`NWListener.State`](https://developer.apple.com/documentation/network/nwlistener/state-swift.enum)
///   — `.setup`, `.waiting(NWError)`, `.ready`, `.failed(NWError)`,
///   `.cancelled`.
public actor QUICRemoteStreamServer: RemoteStreamServer {

    public enum QUICServerError: Error, Sendable, LocalizedError {
        /// The supplied `SecIdentity` couldn't be promoted to a
        /// `sec_identity_t`.  Typically means the identity has
        /// no associated private key, or the key material isn't
        /// accessible to this process (Keychain ACL mismatch).
        case identityRejected
        /// `NWListener.start` transitioned to `.failed` before
        /// reaching `.ready`.
        case startFailed(NWError)
        /// Cancelled before reaching `.ready`.
        case cancelledBeforeReady
        /// ``start()`` was called more than once.
        case alreadyStarted

        public var errorDescription: String? {
            switch self {
            case .identityRejected:
                "QUIC server rejected the supplied TLS identity. Verify the identity has an accessible private key."
            case .startFailed(let error):
                "QUIC listener failed to start: \(error)"
            case .cancelledBeforeReady:
                "QUIC listener was cancelled before reaching the ready state."
            case .alreadyStarted:
                "QUIC server has already been started."
            }
        }
    }

    private let port: NWEndpoint.Port
    private let alpn: [String]
    private let identityLoader: @Sendable () throws -> SecIdentity
    private let queue: DispatchQueue
    private var listener: NWListener?
    private let log = Logger(
        subsystem: "com.spooktacular.transport.quic",
        category: "listener"
    )

    /// `nonisolated let` so ``RemoteStreamServer`` conformance
    /// can vend the stream without hopping through the actor's
    /// executor.
    public nonisolated let incomingStreams: AsyncStream<any RemoteStream>
    private let streamsContinuation: AsyncStream<any RemoteStream>.Continuation

    /// - Parameters:
    ///   - port: TCP-style port number to bind; QUIC runs over
    ///     UDP, but `NWEndpoint.Port` is the cross-transport
    ///     type.
    ///   - alpn: ALPN values to advertise.  Must be non-empty —
    ///     QUIC mandates protocol selection in the TLS 1.3
    ///     handshake; an empty list would reject every
    ///     connection.  This precondition is a QUIC-transport
    ///     detail and stays inside this adapter.
    ///   - identityLoader: Resolved once inside ``start()``
    ///     after the actor hop, keeping the non-Sendable
    ///     `SecIdentity` from ever crossing a boundary.  The
    ///     composition root supplies this closure; application
    ///     callers see only the ``RemoteStreamServer`` port.
    public init(
        port: NWEndpoint.Port,
        alpn: [String],
        identityLoader: @escaping @Sendable () throws -> SecIdentity
    ) {
        precondition(
            !alpn.isEmpty,
            "QUIC adapter: ALPN must be non-empty (required by the TLS 1.3 handshake)."
        )
        self.port = port
        self.alpn = alpn
        self.identityLoader = identityLoader
        self.queue = DispatchQueue(
            label: "com.spooktacular.transport.quic.listener",
            qos: .userInitiated
        )

        // `AsyncStream.makeStream` is the modern (Swift 5.9+)
        // idiom that avoids the implicitly-unwrapped-optional
        // dance around a closure-captured continuation.  Same
        // pattern used in `VirtualMachine.swift` elsewhere in
        // this package.
        let (stream, continuation) = AsyncStream.makeStream(of: (any RemoteStream).self)
        self.incomingStreams = stream
        self.streamsContinuation = continuation
    }

    public func start() async throws {
        guard listener == nil else {
            throw QUICServerError.alreadyStarted
        }

        // `identityLoader` runs inside the actor; its return
        // value (`SecIdentity`) never crosses the actor
        // boundary, so `SecIdentity`'s lack of `Sendable`
        // conformance is not a problem here.
        let identity = try identityLoader()
        guard let secIdentity = sec_identity_create(identity) else {
            throw QUICServerError.identityRejected
        }

        let quicOptions = NWProtocolQUIC.Options(alpn: alpn)
        sec_protocol_options_set_local_identity(
            quicOptions.securityProtocolOptions,
            secIdentity
        )

        let parameters = NWParameters(quic: quicOptions)

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch let nwError as NWError {
            throw QUICServerError.startFailed(nwError)
        }
        self.listener = listener

        // Every accepted connection becomes a `QUICStream` and
        // is yielded on `incomingStreams`.  Callers never see
        // `NWConnection`.
        let continuation = self.streamsContinuation
        let connectionQueue = self.queue
        listener.newConnectionHandler = { connection in
            // Server-side: per Apple's
            // [`NWListener.newConnectionHandler`](https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler)
            // docs, the vended connection is *not* yet
            // started.  `QUICStream` starts it.
            let wrapped = QUICStream(
                connection: connection,
                queue: connectionQueue,
                alreadyStarted: false
            )
            continuation.yield(wrapped)
        }

        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.logReady(port: listener.port)
                    resume.resume()
                    // Swap to a logging-only handler so later
                    // state transitions don't double-resume.
                    listener.stateUpdateHandler = { [weak self] next in
                        self?.logState(next)
                    }
                case .failed(let error):
                    self?.logFailed(error: error)
                    resume.resume(throwing: QUICServerError.startFailed(error))
                case .cancelled:
                    resume.resume(throwing: QUICServerError.cancelledBeforeReady)
                case .setup, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        streamsContinuation.finish()
    }

    // MARK: - Logging (nonisolated — callable from listener's
    // queue without actor hop).

    private nonisolated func logReady(port: NWEndpoint.Port?) {
        log.notice("QUIC listener ready on port \(port?.debugDescription ?? "?", privacy: .public)")
    }

    private nonisolated func logFailed(error: NWError) {
        log.error("QUIC listener failed: \(String(describing: error), privacy: .public)")
    }

    private nonisolated func logState(_ state: NWListener.State) {
        log.debug("QUIC listener state: \(String(describing: state), privacy: .public)")
    }
}

/// `NWConnection` wrapper that presents the ``RemoteStream``
/// port to application code.  `internal` rather than
/// `fileprivate` so both the server and client adapters in
/// this module can wrap their connections through it, but
/// still never escapes `SpooktacularInfrastructureApple`
/// (not `public`) — application-layer code only sees
/// `any RemoteStream`.
///
/// Two construction paths use this type:
///
/// 1. **Server** — `NWListener.newConnectionHandler` vends
///    an *unstarted* connection; Apple's docs are explicit:
///    *"Upon receiving a new connection, you should set
///    update handlers on the connection and start it in
///    order to accept it."*  Pass `alreadyStarted: false`.
/// 2. **Client** — `QUICRemoteStreamClient.connect` calls
///    `start(queue:)` itself to drive the handshake and
///    awaits `.ready` before wrapping.  Pass
///    `alreadyStarted: true`; the wrapper installs its
///    read-loop machinery without re-calling `start()`
///    (Apple's docs don't document idempotence for a
///    second `start` call, so we don't rely on it).
internal final class QUICStream: RemoteStream, @unchecked Sendable {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let receivedContinuation: AsyncThrowingStream<Data, any Error>.Continuation
    public let received: AsyncThrowingStream<Data, any Error>

    init(connection: NWConnection, queue: DispatchQueue, alreadyStarted: Bool) {
        self.connection = connection
        self.queue = queue

        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: Data.self,
            throwing: (any Error).self
        )
        self.received = stream
        self.receivedContinuation = continuation

        // State handler: terminal transitions close /
        // throw the received stream.  We do NOT kick off
        // `scheduleReceive()` from `.ready` here — instead
        // we start the read loop unconditionally below
        // because Apple's
        // [`receive(minimumIncompleteLength:maximumLength:completion:)`](https://developer.apple.com/documentation/network/nwconnection/receive(minimumincompletelength:maximumlength:completion:))
        // docs describe it as a *scheduled* completion
        // handler that fires when bytes arrive.  Receives
        // scheduled before `.ready` are held until the
        // connection is ready, so starting the read loop
        // early is safe and avoids a race where the server
        // path could miss a `.ready` transition that fires
        // between the handler install and our own
        // observation of it.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                self?.receivedContinuation.finish(throwing: error)
            case .cancelled:
                self?.receivedContinuation.finish()
            case .setup, .preparing, .waiting, .ready:
                break
            @unknown default:
                break
            }
        }

        if !alreadyStarted {
            // Server path: start the connection Apple's
            // docs require us to start:
            // https://developer.apple.com/documentation/network/nwlistener/newconnectionhandler
            connection.start(queue: queue)
        }

        scheduleReceive()
    }

    /// Kicks off a read loop via `NWConnection.receive`.  The
    /// API is callback-based; we recurse until the connection
    /// closes.
    ///
    /// Docs: https://developer.apple.com/documentation/network/nwconnection/receive(minimumincompletelength:maximumlength:completion:)
    private func scheduleReceive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receivedContinuation.yield(data)
            }
            if let error {
                self.receivedContinuation.finish(throwing: error)
                return
            }
            if isComplete {
                self.receivedContinuation.finish()
                return
            }
            self.scheduleReceive()
        }
    }

    /// Bridges `NWConnection.send(...completion:)` — a
    /// callback-style Apple API — into `async throws` via a
    /// checked throwing continuation.
    ///
    /// Docs: https://developer.apple.com/documentation/network/nwconnection/send(content:contentcontext:iscomplete:completion:)
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        resume.resume(throwing: error)
                    } else {
                        resume.resume()
                    }
                }
            )
        }
    }

    func cancel() {
        connection.cancel()
    }
}

/// QUIC-backed adapter for the ``RemoteStreamClient`` port.
///
/// Mirrors ``QUICRemoteStreamServer``.  ALPN lives inside;
/// the port signature is transport-agnostic.
///
/// Each call to ``connect(toHost:port:)`` spawns one fresh
/// `NWConnection` configured with `NWParameters(quic:)` +
/// ``alpn``, waits for the `.ready` state, and returns a
/// ``QUICStream`` wrapping it.
///
/// ## Apple APIs used — doc-cited
///
/// - [`NWConnection(host:port:using:)`](https://developer.apple.com/documentation/network/nwconnection/init(host:port:using:))
///   — `convenience init(host: NWEndpoint.Host, port: NWEndpoint.Port, using: NWParameters)`.
/// - [`NWConnection.stateUpdateHandler`](https://developer.apple.com/documentation/network/nwconnection/stateupdatehandler)
///   — `@preconcurrency var stateUpdateHandler: (@Sendable (NWConnection.State) -> Void)?`.
/// - [`NWConnection.State`](https://developer.apple.com/documentation/network/nwconnection/state-swift.enum)
///   — `.setup`, `.waiting(NWError)`, `.preparing`, `.ready`,
///   `.failed(NWError)`, `.cancelled`.
/// - [`NWConnection.start(queue:)`](https://developer.apple.com/documentation/network/nwconnection/start(queue:))
///   — begins establishing the connection on the given
///   queue.
/// - [`NWConnection.cancel()`](https://developer.apple.com/documentation/network/nwconnection/cancel())
///   — used on the failure / cancellation paths.
public struct QUICRemoteStreamClient: RemoteStreamClient {

    /// How the client validates the server's TLS
    /// certificate.  The default (`.systemAnchors`) uses
    /// the operating system's built-in trust store.
    ///
    /// `.acceptAnyCertificate_testOnly` installs a
    /// `sec_protocol_verify_t` that unconditionally accepts
    /// the peer — used only by the transport's unit tests
    /// against a loopback server with a throwaway
    /// self-signed cert.  Keeping this enum case in the
    /// public surface (with the `_testOnly` suffix) is
    /// deliberate: production code reads as
    /// `.systemAnchors`, test code as
    /// `.acceptAnyCertificate_testOnly`, so every grep
    /// for the test mode in production code is immediate.
    public enum TrustMode: Sendable {
        case systemAnchors
        case acceptAnyCertificate_testOnly
    }

    public enum QUICClientError: Error, Sendable, LocalizedError {
        /// Caller passed a port that couldn't be converted to
        /// an `NWEndpoint.Port` (i.e., 0).  `NWEndpoint.Port`'s
        /// failable init rejects zero.
        case invalidPort(UInt16)
        /// The QUIC handshake (TLS 1.3 + QUIC-specific
        /// negotiation) failed.
        case connectFailed(NWError)
        /// The connection was cancelled before reaching
        /// `.ready`.
        case cancelledBeforeReady

        public var errorDescription: String? {
            switch self {
            case .invalidPort(let port):
                "QUIC client: port \(port) is not a valid NWEndpoint.Port (must be 1–65535)."
            case .connectFailed(let error):
                "QUIC connection failed: \(error)"
            case .cancelledBeforeReady:
                "QUIC connection was cancelled before the handshake completed."
            }
        }
    }

    private let alpn: [String]
    private let trustMode: TrustMode
    private let queue: DispatchQueue

    /// - Parameters:
    ///   - alpn: ALPN values to offer during the TLS 1.3
    ///     handshake.  Must match one of the server's
    ///     advertised ALPN values, or the handshake fails.
    ///   - trustMode: How the client validates the server
    ///     certificate.  Defaults to ``TrustMode/systemAnchors``.
    public init(alpn: [String], trustMode: TrustMode = .systemAnchors) {
        precondition(
            !alpn.isEmpty,
            "QUIC adapter: ALPN must be non-empty (required by the TLS 1.3 handshake)."
        )
        self.alpn = alpn
        self.trustMode = trustMode
        self.queue = DispatchQueue(
            label: "com.spooktacular.transport.quic.client",
            qos: .userInitiated
        )
    }

    public func connect(toHost host: String, port: UInt16) async throws -> any RemoteStream {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw QUICClientError.invalidPort(port)
        }

        let quicOptions = NWProtocolQUIC.Options(alpn: alpn)

        // Apply the trust mode to the TLS handshake.
        // Per Apple's docs, [`sec_protocol_options_set_verify_block`](https://developer.apple.com/documentation/security/sec_protocol_options_set_verify_block(_:_:_:))
        // registers a `sec_protocol_verify_t` that receives
        // the peer's `sec_trust_t` and a completion closure
        // that decides accept (`true`) or reject (`false`).
        // We register one only for the test-only mode; the
        // default path leaves the framework's system-anchor
        // validation in place.
        switch trustMode {
        case .systemAnchors:
            break
        case .acceptAnyCertificate_testOnly:
            sec_protocol_options_set_verify_block(
                quicOptions.securityProtocolOptions,
                { _, _, complete in complete(true) },
                queue
            )
        }

        let parameters = NWParameters(quic: quicOptions)

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: parameters
        )

        // Bridge NWConnection's callback-style state machine
        // into a throwing continuation that resumes exactly
        // once when we reach `.ready`, `.failed`, or
        // `.cancelled`.  The `stateUpdateHandler` is set
        // *before* `start()` to close the race where the
        // connection could transition to a terminal state
        // between `start` returning and the handler being
        // installed.
        try await withCheckedThrowingContinuation { (resume: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume.resume()
                    // Swap to a no-op so the QUICStream
                    // wrapper can install its own handler
                    // for read-loop lifecycle management.
                    connection.stateUpdateHandler = nil
                case .failed(let error):
                    connection.cancel()
                    resume.resume(throwing: QUICClientError.connectFailed(error))
                case .cancelled:
                    resume.resume(throwing: QUICClientError.cancelledBeforeReady)
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        // Client-side: we already called `start(queue:)`
        // inside the throwing-continuation block above and
        // waited for `.ready`, so pass
        // `alreadyStarted: true` to suppress the redundant
        // second start (Apple's docs don't document a
        // second `start` call as idempotent, so we don't
        // rely on it).
        return QUICStream(
            connection: connection,
            queue: queue,
            alreadyStarted: true
        )
    }
}
