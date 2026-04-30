import Foundation
import Network
import os
import SpooktacularApplication

/// HTTPS-capable listener for Apple's MDM check-in + command
/// protocol, scoped to the two endpoints `mdmclient` calls
/// during enrollment + InstallApplication delivery:
///
/// | Method | Path           | Body                                    |
/// |--------|----------------|-----------------------------------------|
/// | PUT    | /mdm/checkin   | XML plist — Authenticate / TokenUpdate / CheckOut |
/// | PUT    | /mdm/server    | XML plist — ServerCommandResponse, OR empty body for an idle poll |
///
/// Responses are XML-format plists (or empty bodies for "no
/// commands" / "ack accepted").
///
/// ## Why a separate server, not part of HTTPAPIServer
///
/// `HTTPAPIServer` is the JSON API surface (`spook serve`) —
/// authenticated with P-256 signed requests, returns
/// `{"status":"ok",…}` envelopes. The MDM endpoint is plist
/// over HTTP and is mTLS-authenticated against per-VM
/// identity certs. Mixing them would force every request
/// through dual auth checks. Keeping them separate keeps
/// concerns clear and lets the MDM server scale independently
/// (one instance per `spook serve`, one TLS cert chain, one
/// listener port).
///
/// ## TLS posture
///
/// Phase 3 ships HTTP-on-loopback for local-development /
/// CI traffic, with a clear hook to swap in
/// `NWProtocolTLS.Options` once Phase 2's CA work lands.
/// Production deployments will enforce TLS and reject any
/// request without a valid client identity cert that chains
/// to the embedded MDM root CA.
///
/// ## Hardening
///
/// Loopback-only by default — no public-internet surface, so
/// the slow-loris / large-body defenses `HTTPAPIServer` needs
/// are overkill here. We still cap `maxRequestBytes` so a
/// runaway client can't fill memory.
public actor EmbeddedMDMServer {

    // MARK: - Defaults

    /// Default port. Picked outside the privileged-port range
    /// so the server can bind without sudo. Configurable via
    /// the initializer for test isolation.
    public static let defaultPort: UInt16 = 8443

    /// Per-request body cap. Apple's MDM protocol bodies are
    /// small (a few KB at most for check-ins + responses); 1
    /// MiB is generous-but-bounded.
    private static let maxRequestBytes = 1 * 1024 * 1024

    // MARK: - Endpoints

    static let checkInPath = "/mdm/checkin"
    static let commandPath = "/mdm/server"
    static let manifestPathPrefix = "/mdm/manifest/"
    static let pkgPathPrefix = "/mdm/pkg/"

    // MARK: - Properties

    private let host: String
    private let port: NWEndpoint.Port
    private let handler: any MDMServerHandler
    private let contentStore: MDMContentStore?
    private let logger: Logger
    private var listener: NWListener?
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    // MARK: - Init

    /// - Parameters:
    ///   - host: Bind address. Defaults to `127.0.0.1` so the
    ///     server is invisible from the host's external NIC
    ///     until production deploys it on a routable address.
    ///   - port: TCP port. Defaults to ``defaultPort``.
    ///   - handler: Policy implementation —
    ///     ``SpooktacularMDMHandler`` in production, mocks in
    ///     tests.
    ///   - logger: Subsystem-scoped logger.
    public init(
        host: String = "127.0.0.1",
        port: UInt16 = defaultPort,
        handler: any MDMServerHandler,
        contentStore: MDMContentStore? = nil,
        logger: Logger = Logger(
            subsystem: "com.spookylabs.spooktacular",
            category: "mdm.server"
        )
    ) throws {
        // Port 0 is the test escape hatch for "OS-assigned
        // ephemeral port" — NWListener uses `.any` for that.
        // Anything else must be a valid 1–65535 value.
        let nwPort: NWEndpoint.Port
        if port == 0 {
            nwPort = .any
        } else {
            guard let parsed = NWEndpoint.Port(rawValue: port) else {
                throw EmbeddedMDMServerError.invalidPort(port)
            }
            nwPort = parsed
        }
        self.host = host
        self.port = nwPort
        self.handler = handler
        self.contentStore = contentStore
        self.logger = logger
    }

    // MARK: - Lifecycle

    /// Binds the listener and begins accepting connections.
    /// Awaits the listener entering `.ready` state so callers
    /// (especially tests passing `port: 0` to let the OS pick)
    /// can read the actual bound port immediately afterwards
    /// via ``boundPort``. Idempotent — calling `start()` on an
    /// already-running server is a no-op.
    public func start() async throws {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        // Bind to specific host (loopback by default) rather
        // than 0.0.0.0 so the server is invisible to anything
        // not on this address. Tests pass "127.0.0.1"; future
        // production deployments will pass the bridged-NIC IP
        // VMs reach the host on.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: port
        )
        // Allow the port to be reused if we recently shut
        // down — important for tests that bind, tear down, and
        // re-bind in quick succession.
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            throw EmbeddedMDMServerError.bindFailed(error)
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        // Bridge the listener's stateUpdateHandler into a
        // continuation so `start()` can await binding. NWListener
        // calls `.ready` once it has its actual port; before
        // that, `listener.port` returns nil. Use a reference
        // type for the "resumed once" guard so the
        // stateUpdateHandler (Sendable) can mutate it under a
        // lock without tripping the concurrency checker.
        let guardOnce = OneShotGuard()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if guardOnce.tryResume() { cont.resume() }
                case .failed(let error):
                    if guardOnce.tryResume() {
                        cont.resume(throwing: EmbeddedMDMServerError.bindFailed(error))
                    }
                case .cancelled:
                    if guardOnce.tryResume() {
                        cont.resume(throwing: EmbeddedMDMServerError.listenerCancelled)
                    }
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        logger.notice(
            "MDM server bound to \(self.host, privacy: .public):\(self.boundPort ?? 0, privacy: .public)"
        )
    }

    /// Cancels the listener and all active connections. Safe
    /// to call from any context; not awaited because we don't
    /// care about cancellation completion ordering — the OS
    /// reaps the file descriptors.
    public func stop() {
        listener?.cancel()
        listener = nil
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()
    }

    /// Bound port number. Useful in tests when a 0 is passed
    /// in to let the OS pick.
    public var boundPort: UInt16? {
        listener?.port?.rawValue
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        activeConnections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.remove(connection) }
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        receiveRequest(on: connection, buffer: Data())
    }

    private func remove(_ connection: NWConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private nonisolated func receiveRequest(on connection: NWConnection, buffer: Data) {
        let chunk = max(0, Self.maxRequestBytes - buffer.count)
        guard chunk > 0 else {
            sendResponse(statusCode: 413, body: nil, contentType: nil, on: connection)
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: min(chunk, 65_536)
        ) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }

            do {
                switch try HTTPRequestParser.parseIfComplete(
                    next, maxRequestBytes: Self.maxRequestBytes
                ) {
                case .complete(let request):
                    Task { await self.dispatch(request, on: connection) }
                case .needMore:
                    if isComplete {
                        // Connection closed before we got a
                        // full request — drop quietly.
                        connection.cancel()
                        return
                    }
                    self.receiveRequest(on: connection, buffer: next)
                case .tooLarge:
                    self.sendResponse(
                        statusCode: 413, body: nil,
                        contentType: nil, on: connection
                    )
                }
            } catch {
                self.sendResponse(
                    statusCode: 400, body: nil,
                    contentType: nil, on: connection
                )
            }
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) async {
        // Static routes first.
        switch request.path {
        case Self.checkInPath:
            await handleCheckIn(request, on: connection)
            return
        case Self.commandPath:
            await handleCommand(request, on: connection)
            return
        default:
            break
        }
        // Prefix-matched manifest + pkg routes — only on GET,
        // since the device fetches them with HTTP GET when
        // resolving the InstallEnterpriseApplication command.
        if request.method == "GET" {
            if let id = idFrom(path: request.path, prefix: Self.manifestPathPrefix) {
                await handleManifestFetch(id: id, on: connection)
                return
            }
            if let id = idFrom(path: request.path, prefix: Self.pkgPathPrefix) {
                await handlePkgFetch(id: id, on: connection)
                return
            }
        }
        sendResponse(
            statusCode: 404, body: nil,
            contentType: nil, on: connection
        )
    }

    private nonisolated func idFrom(path: String, prefix: String) -> UUID? {
        guard path.hasPrefix(prefix) else { return nil }
        let raw = String(path.dropFirst(prefix.count))
        return UUID(uuidString: raw)
    }

    private func handleManifestFetch(id: UUID, on connection: NWConnection) async {
        guard let store = contentStore,
              let bytes = await store.manifest(forID: id) else {
            sendResponse(statusCode: 404, body: nil, contentType: nil, on: connection)
            return
        }
        sendResponse(
            statusCode: 200,
            body: bytes,
            contentType: "application/xml",
            on: connection
        )
    }

    private func handlePkgFetch(id: UUID, on connection: NWConnection) async {
        guard let store = contentStore,
              let bytes = await store.pkg(forID: id) else {
            sendResponse(statusCode: 404, body: nil, contentType: nil, on: connection)
            return
        }
        sendResponse(
            statusCode: 200,
            body: bytes,
            // Apple's installer recognizes pkg payloads by
            // content-type or by the magic bytes; both are fine.
            contentType: "application/octet-stream",
            on: connection
        )
    }

    private func handleCheckIn(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let body = request.body, !body.isEmpty else {
            sendResponse(statusCode: 400, body: nil, contentType: nil, on: connection)
            return
        }
        do {
            let message = try MDMCheckInMessage.decode(plistBody: body)
            switch message {
            case .authenticate(let auth):
                await handler.didReceiveAuthenticate(auth)
            case .tokenUpdate(let token):
                await handler.didReceiveTokenUpdate(token)
            case .checkOut(let checkOut):
                await handler.didReceiveCheckOut(checkOut)
            case .unsupported(let messageType, _):
                logger.info(
                    "Tolerating unsupported MessageType=\(messageType, privacy: .public)"
                )
            }
            // Apple's `mdmclient` accepts an empty 200 response
            // for any check-in. We don't echo any payload back.
            sendResponse(
                statusCode: 200, body: nil,
                contentType: nil, on: connection
            )
        } catch {
            logger.error("Check-in decode failed: \(String(describing: error), privacy: .public)")
            sendResponse(statusCode: 400, body: nil, contentType: nil, on: connection)
        }
    }

    private func handleCommand(_ request: HTTPRequest, on connection: NWConnection) async {
        // The /mdm/server path is overloaded by HTTP method:
        // - body absent / empty → idle poll, ask handler for
        //   the next command
        // - body present → ServerCommandResponse from the
        //   device, ack the in-flight command and then look
        //   for the next one to send back.
        var udidForReply: String?

        if let body = request.body, !body.isEmpty {
            do {
                let response = try MDMCommandResponse.decode(plistBody: body)
                udidForReply = response.udid
                switch response.status {
                case .acknowledged, .error, .notNow:
                    await handler.didReceiveCommandResponse(
                        forUDID: response.udid,
                        commandUUID: response.commandUUID,
                        status: response.status
                    )
                case .idle:
                    // No previous command to ack; fall through
                    // to dispatch.
                    break
                }
            } catch {
                logger.error(
                    "Response decode failed: \(String(describing: error), privacy: .public)"
                )
                sendResponse(statusCode: 400, body: nil, contentType: nil, on: connection)
                return
            }
        } else {
            // Empty-body poll — `mdmclient` sometimes does this
            // shape during initial handshake. Without a UDID
            // we can't dispatch a command, so reply 200 empty.
            sendResponse(statusCode: 200, body: nil, contentType: nil, on: connection)
            return
        }

        guard let udid = udidForReply else {
            sendResponse(statusCode: 200, body: nil, contentType: nil, on: connection)
            return
        }

        if let next = await handler.nextCommand(forUDID: udid) {
            do {
                let plist = try next.wirePlist()
                sendResponse(
                    statusCode: 200,
                    body: plist,
                    contentType: "application/xml",
                    on: connection
                )
            } catch {
                logger.error(
                    "Command encode failed: \(String(describing: error), privacy: .public)"
                )
                sendResponse(statusCode: 500, body: nil, contentType: nil, on: connection)
            }
        } else {
            // No commands queued — `mdmclient` reads HTTP 200
            // with an empty body as "go idle, poll later."
            sendResponse(statusCode: 200, body: nil, contentType: nil, on: connection)
        }
    }

    // MARK: - Response writer

    private nonisolated func sendResponse(
        statusCode: Int,
        body: Data?,
        contentType: String?,
        on connection: NWConnection
    ) {
        var head = "HTTP/1.1 \(statusCode) \(Self.statusText(statusCode))\r\n"
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        if let body {
            out.append(body)
        }
        connection.send(content: out, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func statusText(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}

// MARK: - One-shot guard

/// Tiny lock-protected "resume once" flag used by ``start()``
/// to make sure the listener-state continuation is resumed
/// exactly once across whatever order `.ready` /`.failed` /
/// `.cancelled` arrive in. NSLock-backed for portability.
private final class OneShotGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryResume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !fired else { return false }
        fired = true
        return true
    }
}

// MARK: - Errors

/// Errors thrown by ``EmbeddedMDMServer``.
public enum EmbeddedMDMServerError: Error, Sendable {
    /// The supplied port wasn't in the valid range (1–65535).
    case invalidPort(UInt16)
    /// `NWListener(using:on:)` rejected the parameters — most
    /// commonly because the port is already bound by another
    /// process.
    case bindFailed(Error)
    /// The listener was cancelled before it reached `.ready`.
    /// Surfaces when the server is asked to shut down during
    /// `start()`.
    case listenerCancelled
}
