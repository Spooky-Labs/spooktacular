import Foundation
import SpookCore
import SpookApplication
import Network
import Security
import os

// MARK: - HTTP API Server

/// A lightweight HTTP API server for managing virtual machines programmatically.
///
/// `HTTPAPIServer` provides a RESTful JSON API built on Apple's
/// `Network.framework` (`NWListener`). It exposes endpoints for
/// listing, creating, starting, stopping, and deleting VMs, as well as
/// resolving VM IP addresses and performing health checks.
///
/// **TLS is required in production.** Provide `NWProtocolTLS.Options`
/// at initialization. The `--insecure` flag is available for local
/// development only — production startup without TLS or an API token
/// will fail with ``HTTPAPIServerError/missingAPIToken``.
///
/// Set the `SPOOK_API_TOKEN` environment variable to require
/// Bearer-token authentication on all endpoints except `/health`.
///
/// ## Endpoints
///
/// | Method | Path | Description |
/// |--------|------|-------------|
/// | `GET` | `/health` | Health check |
/// | `GET` | `/v1/vms` | List all VMs |
/// | `GET` | `/v1/vms/:name` | Get VM details |
/// | `POST` | `/v1/vms` | Create a new VM (requires IPSW; prefer clone) |
/// | `POST` | `/v1/vms/:name/clone` | Clone a VM from a base image |
/// | `POST` | `/v1/vms/:name/start` | Start a VM |
/// | `POST` | `/v1/vms/:name/stop` | Stop a VM |
/// | `DELETE` | `/v1/vms/:name` | Delete a VM |
/// | `GET` | `/v1/vms/:name/ip` | Resolve VM IP address |
/// | `GET` | `/metrics` | Prometheus metrics |
///
/// ## Response Format
///
/// All responses use a consistent JSON envelope:
///
/// ```json
/// {"status": "ok", "data": { ... }}
/// {"status": "error", "message": "VM 'foo' not found."}
/// ```
///
/// ## Usage
///
/// ```swift
/// let server = try HTTPAPIServer(
///     host: "127.0.0.1",
///     port: 8484,
///     vmDirectory: Paths.vms,
///     spookPath: "/usr/local/bin/spook"
/// )
/// try await server.start()
/// ```
///
/// ## Thread Safety
///
/// `HTTPAPIServer` is an `actor`, ensuring all mutable state is accessed
/// serially. Connection handling and request routing run on the Network
/// framework's internal dispatch queues, with results forwarded back to
/// the actor for safe mutation.
public actor HTTPAPIServer {

    // MARK: - Defaults

    /// The default TCP port for the HTTP API server.
    public static let defaultPort: UInt16 = 8484

    /// The default path to the `spook` binary.
    public static let defaultSpookPath: String = "/usr/local/bin/spook"

    // MARK: - Properties

    /// The NWListener that accepts incoming TCP connections.
    ///
    /// This is mutable to support TLS certificate hot reload, which
    /// requires replacing the listener with new TLS parameters.
    private var listener: NWListener

    /// The host address the server is bound to.
    private let host: String

    /// The TCP port the server is listening on.
    private let port: NWEndpoint.Port

    /// The directory containing `.vm` bundle directories.
    private let vmDirectory: URL

    /// The absolute path to the `spook` binary, used when spawning
    /// detached VM processes (e.g., `spook start --headless`).
    private let spookPath: String

    /// Optional Bearer token for API authentication.
    ///
    /// When set (via the `SPOOK_API_TOKEN` environment variable), every
    /// request except `GET /health` must include an `Authorization:
    /// Bearer <token>` header. When `nil`, all requests are allowed
    /// (development mode).
    private let apiToken: String?

    /// Whether the server is running in insecure development mode.
    /// When `true`, TLS and API token requirements are bypassed.
    /// **Not suitable for production.** Use `--insecure` flag only
    /// for local development and testing.
    public let insecureMode: Bool

    /// Logger for HTTP API events.
    private let logger = Log.httpAPI

    /// Tracks whether the server is currently running.
    private var isRunning = false

    /// Active connections tracked for clean shutdown.
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    /// Maximum concurrent connections. Override with `SPOOK_MAX_CONNECTIONS` env var.
    private let maxConcurrentConnections: Int

    /// Current number of active connections.
    private var activeConnectionCount: Int = 0

    /// Per-client rate limit: max requests per minute. Override with `SPOOK_RATE_LIMIT` env var.
    private let maxRequestsPerMinute: Int

    /// Maximum total bytes (headers + body) accepted for a single request.
    ///
    /// Oversized requests are rejected with HTTP 413 before the body is
    /// fully buffered. Defaults to 1 MiB; override with
    /// `SPOOK_MAX_REQUEST_BYTES`.
    private let maxRequestBytes: Int

    /// Maximum seconds to wait for a complete request after the first byte.
    ///
    /// Clients that send bytes more slowly than this (the slow-loris
    /// family of denial-of-service attacks) are rejected with HTTP 408.
    /// Defaults to 30 s; override with `SPOOK_REQUEST_TIMEOUT_SECONDS`.
    private let requestTimeoutSeconds: TimeInterval

    /// Default maximum request size: 1 MiB.
    private static let defaultMaxRequestBytes = 1 << 20

    /// Default request read timeout: 30 seconds.
    private static let defaultRequestTimeoutSeconds: TimeInterval = 30

    /// Tracks request counts per client IP for rate limiting.
    private var clientRequestCounts: [String: (count: Int, windowStart: Date)] = [:]

    /// The tenant identity for this server instance.
    ///
    /// In single-tenant mode this is ``TenantID/default``. In multi-tenant
    /// mode it identifies which tenant this node belongs to so that
    /// all API operations carry proper tenant context for audit and
    /// isolation enforcement.
    private let tenantID: TenantID

    /// Optional authorization service for RBAC enforcement.
    ///
    /// When set, every API request is checked against the actor's
    /// roles before dispatching to the handler. Deny by default.
    private let authService: (any AuthorizationService)?

    /// Optional structured audit sink for control-plane actions.
    ///
    /// When set, every API request emits a structured ``AuditRecord``
    /// through this sink. Defaults to `nil` for backward compatibility.
    private let auditSink: (any AuditSink)?

    /// Dispatch source monitoring the TLS certificate file for changes.
    ///
    /// Retained here to keep the file-system event source alive for the
    /// lifetime of the server (or until ``stopWatchingCertificates()``
    /// is called).
    private var certFileWatcher: (any DispatchSourceFileSystemObject)?

    // MARK: - Initialization

    /// Creates a new HTTP API server.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address to bind to. Defaults to
    ///     `"127.0.0.1"` (localhost only).
    ///   - port: The TCP port to listen on. Defaults to `8484`.
    ///   - vmDirectory: The directory containing VM bundles
    ///     (typically `~/.spooktacular/vms/`).
    ///   - spookPath: The absolute path to the `spook` binary for
    ///     spawning VM processes. Defaults to `/usr/local/bin/spook`.
    ///   - tlsOptions: Optional TLS configuration for the NWListener.
    ///     When provided, the server accepts HTTPS connections using
    ///     the supplied certificate and key. Required in production.
    ///     When `nil`, requires `insecureMode: true` or startup fails.
    ///   - tenantID: The tenant identity for this server instance.
    ///     Defaults to ``TenantID/default`` for single-tenant
    ///     deployments.
    ///   - auditSink: Optional structured audit sink. When provided,
    ///     every API request emits an ``AuditRecord``. Defaults to
    ///     `nil` (no structured audit — existing os.Logger behavior).
    ///   - insecureMode: When `true`, disables the requirement for an
    ///     API token when TLS is not configured. The server logs a
    ///     prominent warning when running in insecure mode.
    /// - Throws: ``HTTPAPIServerError/invalidPort(_:)`` if the port
    ///   number is invalid, or ``HTTPAPIServerError/missingAPIToken``
    ///   if TLS is disabled, `insecureMode` is `false`, and no
    ///   `SPOOK_API_TOKEN` environment variable is set.
    public init(
        host: String,
        port: UInt16 = 8484,
        vmDirectory: URL,
        spookPath: String = "/usr/local/bin/spook",
        tlsOptions: NWProtocolTLS.Options? = nil,
        tenantID: TenantID = .default,
        authService: (any AuthorizationService)? = nil,
        auditSink: (any AuditSink)? = nil,
        insecureMode: Bool = false
    ) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPAPIServerError.invalidPort(port)
        }

        let parameters: NWParameters
        if let tlsOptions {
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = NWParameters.tcp
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        self.listener = try NWListener(using: parameters)
        self.host = host
        self.port = nwPort
        self.vmDirectory = vmDirectory
        self.spookPath = spookPath
        self.tenantID = tenantID
        self.authService = authService
        self.auditSink = auditSink
        self.insecureMode = insecureMode
        self.maxConcurrentConnections = Int(ProcessInfo.processInfo.environment["SPOOK_MAX_CONNECTIONS"] ?? "") ?? 50
        self.maxRequestsPerMinute = Int(ProcessInfo.processInfo.environment["SPOOK_RATE_LIMIT"] ?? "") ?? 120
        self.maxRequestBytes = Int(ProcessInfo.processInfo.environment["SPOOK_MAX_REQUEST_BYTES"] ?? "")
            ?? Self.defaultMaxRequestBytes
        self.requestTimeoutSeconds = Double(ProcessInfo.processInfo.environment["SPOOK_REQUEST_TIMEOUT_SECONDS"] ?? "")
            ?? Self.defaultRequestTimeoutSeconds

        let token = ProcessInfo.processInfo.environment["SPOOK_API_TOKEN"]
        self.apiToken = token?.isEmpty == false ? token : nil

        if insecureMode {
            Log.httpAPI.warning("⚠️  SERVER RUNNING IN INSECURE MODE — no TLS, no required API token")
            Log.httpAPI.warning("⚠️  Do NOT expose this server to untrusted networks")
        } else if tlsOptions == nil && self.apiToken == nil {
            throw HTTPAPIServerError.missingAPIToken
        }
    }

    // MARK: - Lifecycle

    /// Starts the HTTP server and blocks until it is stopped.
    ///
    /// The server accepts TCP connections, parses HTTP requests,
    /// routes them to the appropriate handler, and sends JSON
    /// responses. It runs until ``stop()`` is called or the process
    /// receives a termination signal.
    ///
    /// - Throws: An error if the listener fails to start.
    public func start() async throws {
        guard !isRunning else {
            logger.warning("Server is already running")
            return
        }
        isRunning = true

        let endpoint = listener.parameters.requiredLocalEndpoint
        logger.notice("Starting HTTP API server on \(endpoint.debugDescription, privacy: .public)")

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        // Use a single stateUpdateHandler that both logs state
        // transitions AND resumes the startup continuation. A
        // `didResume` flag prevents a double-resume crash if
        // the listener transitions more than once after .ready.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Use nonisolated(unsafe) because NWListener's
            // stateUpdateHandler is not @Sendable but we need
            // to track whether the continuation was resumed.
            nonisolated(unsafe) var didResume = false
            listener.stateUpdateHandler = { [logger] state in
                switch state {
                case .ready:
                    logger.notice("HTTP API server is ready and listening")
                    if !didResume {
                        didResume = true
                        continuation.resume()
                    }
                case .failed(let error):
                    logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    logger.notice("Listener cancelled")
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: HTTPAPIServerError.cancelled)
                    }
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Stops the HTTP server and cancels all active connections.
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        logger.notice("Stopping HTTP API server")

        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()

        listener.cancel()
    }

    // MARK: - TLS Certificate Hot Reload

    /// Reloads TLS certificates from the given identity.
    ///
    /// Creates a new `NWProtocolTLS.Options`, updates the listener's
    /// parameters, and restarts the listener on the same port.
    /// Existing connections are drained gracefully.
    ///
    /// - Parameter identity: The new `SecIdentity` containing the
    ///   rotated certificate and private key.
    /// - Throws: An error if the new listener fails to start.
    public func reloadTLS(identity: SecIdentity) async throws {
        logger.notice("Reloading TLS certificates")

        let newOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            newOptions.securityProtocolOptions,
            sec_identity_create(identity)!
        )

        let parameters = NWParameters(tls: newOptions)
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: port
        )

        // Drain existing connections gracefully.
        for connection in activeConnections.values {
            connection.cancel()
        }
        activeConnections.removeAll()

        // Stop the current listener.
        listener.cancel()

        // Create and start a new listener with the updated TLS parameters.
        let newListener = try NWListener(using: parameters)
        self.listener = newListener

        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            nonisolated(unsafe) var didResume = false
            newListener.stateUpdateHandler = { [logger] state in
                switch state {
                case .ready:
                    logger.notice("TLS-reloaded listener is ready")
                    if !didResume {
                        didResume = true
                        continuation.resume()
                    }
                case .failed(let error):
                    logger.error("TLS-reloaded listener failed: \(error.localizedDescription, privacy: .public)")
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    logger.notice("TLS-reloaded listener cancelled")
                    if !didResume {
                        didResume = true
                        continuation.resume(throwing: HTTPAPIServerError.cancelled)
                    }
                default:
                    break
                }
            }

            newListener.start(queue: .global(qos: .userInitiated))
        }

        logger.notice("TLS certificates reloaded successfully")
    }

    /// Starts monitoring a TLS certificate file for changes.
    ///
    /// Uses `DispatchSource.makeFileSystemObjectSource` to watch the
    /// certificate file for writes and renames. When a change is
    /// detected, ``loadIdentity`` is called to re-read the PEM files
    /// and ``reloadTLS(identity:)`` performs the hot swap.
    ///
    /// - Parameters:
    ///   - certPath: Path to the PEM-encoded certificate file to watch.
    ///   - keyPath: Path to the PEM-encoded private key file.
    ///   - loadIdentity: A closure that reads the cert and key files
    ///     and returns a `SecIdentity`. This is injected from the CLI
    ///     layer so the server does not own PEM parsing.
    /// - Throws: ``HTTPAPIServerError/certificateFileNotFound(_:)`` if
    ///   the certificate file cannot be opened for monitoring.
    public func watchCertificates(
        certPath: String,
        keyPath: String,
        loadIdentity: @escaping @Sendable (String, String) throws -> SecIdentity
    ) throws {
        let fd = open(certPath, O_EVTONLY)
        guard fd >= 0 else {
            throw HTTPAPIServerError.certificateFileNotFound(certPath)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.handleCertificateFileChange(
                    certPath: certPath,
                    keyPath: keyPath,
                    loadIdentity: loadIdentity
                )
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        // If we were already watching, cancel the old source.
        certFileWatcher?.cancel()
        certFileWatcher = source
        source.resume()

        logger.notice("Watching TLS certificate file for changes: \(certPath, privacy: .public)")
    }

    /// Stops monitoring the TLS certificate file.
    public func stopWatchingCertificates() {
        certFileWatcher?.cancel()
        certFileWatcher = nil
    }

    /// Handles a detected change in the certificate file.
    ///
    /// Re-reads the PEM files, constructs a new identity, and performs
    /// the TLS hot reload. On failure the server continues running
    /// with the previous certificates and logs the error.
    private func handleCertificateFileChange(
        certPath: String,
        keyPath: String,
        loadIdentity: @escaping @Sendable (String, String) throws -> SecIdentity
    ) async {
        do {
            let identity = try loadIdentity(certPath, keyPath)
            try await reloadTLS(identity: identity)
            logger.notice("TLS certificates rotated successfully")
        } catch {
            logger.error("TLS certificate rotation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Connection Handling

    /// Accepts a new TCP connection and processes HTTP requests on it.
    private func handleNewConnection(_ connection: NWConnection) {
        // Reject if at capacity
        guard activeConnectionCount < maxConcurrentConnections else {
            connection.cancel()
            logger.warning("Connection rejected: at capacity (\(self.maxConcurrentConnections))")
            return
        }
        activeConnectionCount += 1

        activeConnections[ObjectIdentifier(connection)] = connection
        let logger = self.logger

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                logger.debug("Connection ready from \(connection.endpoint.debugDescription, privacy: .public)")
            case .failed(let error):
                logger.debug("Connection failed: \(error.localizedDescription, privacy: .public)")
                Task { await self?.removeConnection(connection) }
            case .cancelled:
                Task { await self?.removeConnection(connection) }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        receiveRequest(on: connection)
    }

    /// Removes a connection from the active set and decrements the active count.
    private func removeConnection(_ connection: NWConnection) {
        if activeConnections.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            activeConnectionCount -= 1
        }
    }

    /// Reads bytes from a connection, buffering until a complete HTTP
    /// request has arrived or a safety limit trips.
    ///
    /// Enforces three safety limits:
    /// - **Total size** (`maxRequestBytes`): rejects with HTTP 413 before
    ///   the body is fully read, defeating memory-exhaustion attacks.
    /// - **Total time** (`requestTimeoutSeconds`): rejects with HTTP 408
    ///   when the client sends bytes too slowly (slow-loris).
    /// - **Malformed headers**: rejects with HTTP 400 as soon as the
    ///   header block is complete and unparseable.
    private nonisolated func receiveRequest(on connection: NWConnection) {
        readIntoBuffer(
            on: connection,
            buffer: Data(),
            deadline: Date().addingTimeInterval(requestTimeoutSeconds),
            maxBytes: maxRequestBytes
        )
    }

    /// Recursive reader that accumulates bytes until a complete request
    /// is parseable or a limit is exceeded.
    private nonisolated func readIntoBuffer(
        on connection: NWConnection,
        buffer: Data,
        deadline: Date,
        maxBytes: Int
    ) {
        if Date() > deadline {
            let response = HTTPResponse.error(message: "Request Timeout.", statusCode: 408)
            sendResponse(response, on: connection)
            return
        }

        let remaining = maxBytes - buffer.count
        guard remaining > 0 else {
            let response = HTTPResponse.error(message: "Payload Too Large.", statusCode: 413)
            sendResponse(response, on: connection)
            return
        }

        let chunk = min(remaining, 65_536)
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            var next = buffer
            if let data { next.append(data) }

            if next.count > maxBytes {
                let response = HTTPResponse.error(message: "Payload Too Large.", statusCode: 413)
                self.sendResponse(response, on: connection)
                return
            }

            do {
                if let request = try HTTPRequestParser.parseIfComplete(next) {
                    Task { await self.processParsedRequest(request, on: connection) }
                    return
                }
            } catch {
                let response = HTTPResponse.error(message: "Malformed HTTP request.", statusCode: 400)
                self.sendResponse(response, on: connection)
                return
            }

            if error != nil || isComplete {
                // Connection closed before a full request arrived.
                connection.cancel()
                return
            }

            self.readIntoBuffer(on: connection, buffer: next, deadline: deadline, maxBytes: maxBytes)
        }
    }

    /// Checks whether a client IP is within its rate limit window.
    ///
    /// Each client is allowed ``maxRequestsPerMinute`` requests per
    /// 60-second sliding window. Returns `true` if the request is
    /// allowed, `false` if rate-limited.
    ///
    /// - Parameter clientIP: The IP address string of the connecting client.
    /// - Returns: `true` if the request should proceed; `false` if rate-limited.
    func checkRateLimit(clientIP: String) -> Bool {
        let now = Date()
        if let entry = clientRequestCounts[clientIP] {
            if now.timeIntervalSince(entry.windowStart) > 60 {
                // New window
                clientRequestCounts[clientIP] = (count: 1, windowStart: now)
                return true
            } else if entry.count >= maxRequestsPerMinute {
                return false
            } else {
                clientRequestCounts[clientIP] = (count: entry.count + 1, windowStart: entry.windowStart)
                return true
            }
        } else {
            clientRequestCounts[clientIP] = (count: 1, windowStart: now)
            return true
        }
    }

    /// Extracts a client IP string from an `NWConnection`'s remote endpoint.
    ///
    /// Falls back to the endpoint's debug description when the endpoint
    /// is not a host-port pair.
    private func clientIP(from connection: NWConnection) -> String {
        switch connection.endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return connection.endpoint.debugDescription
        }
    }

    /// Dispatches a fully-parsed request: logs, rate-limits, routes.
    private func processParsedRequest(_ request: HTTPRequest, on connection: NWConnection) async {
        logger.info("\(request.method, privacy: .public) \(request.path, privacy: .public)")

        let ip = clientIP(from: connection)
        guard checkRateLimit(clientIP: ip) else {
            logger.warning("Rate limit exceeded for \(ip, privacy: .public)")
            let response = HTTPResponse.error(message: "Too Many Requests.", statusCode: 429)
            sendResponse(response, on: connection)
            return
        }

        let response = await routeRequest(request)
        sendResponse(response, on: connection)
    }

    /// Sends an HTTP response on the connection and then closes it.
    private nonisolated func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    /// Regex for valid VM names: alphanumeric start, then up to 62 more
    /// alphanumeric, dot, underscore, or hyphen characters.
    private nonisolated(unsafe) static let vmNamePattern = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$/

    /// Constant-time string equality.
    ///
    /// Compares byte-by-byte without short-circuiting, so the running
    /// time depends only on length, not on which bytes match. This is
    /// the primitive that prevents bearer-token-enumeration timing
    /// attacks on the Authorization header.
    ///
    /// Length is treated as non-secret and checked first — bailing out
    /// on length is standard and does not constitute a timing leak.
    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[i] ^ b[i]
        }
        return diff == 0
    }

    /// Routes an HTTP request to the appropriate handler based on method and path.
    ///
    /// Path matching uses simple prefix/component matching:
    /// - `/health` -- health check (unauthenticated)
    /// - `/metrics` -- Prometheus metrics (authenticated when token set)
    /// - `/v1/vms` -- list or create VMs
    /// - `/v1/vms/:name` -- get or delete a specific VM
    /// - `/v1/vms/:name/clone` -- clone a base VM
    /// - `/v1/vms/:name/start` -- start a VM
    /// - `/v1/vms/:name/stop` -- stop a VM
    /// - `/v1/vms/:name/ip` -- resolve VM IP
    ///
    /// When `SPOOK_API_TOKEN` is configured, all routes except `/health`
    /// require a matching `Authorization: Bearer <token>` header.
    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let components = request.path
            .split(separator: "/")
            .map(String.init)

        if request.method == "GET" && request.path == "/health" {
            return handleHealth()
        }

        if let token = apiToken {
            let header = request.headers["authorization"] ?? ""
            guard Self.constantTimeEqual(header, "Bearer \(token)") else {
                let response = HTTPResponse.error(message: "Unauthorized.", statusCode: 401)
                await emitAPIAudit(method: request.method, path: request.path, statusCode: response.statusCode)
                return response
            }
        }

        // RBAC enforcement: check resource-level permissions before dispatch.
        if let auth = authService {
            let resource = inferResource(from: request.path)
            let action = inferAction(from: request.method, path: request.path)
            let context = AuthorizationContext(
                actorIdentity: "api-client",
                tenant: tenantID,
                scope: .admin,
                resource: resource,
                action: action
            )
            guard await auth.authorize(context) else {
                let response = HTTPResponse.error(
                    message: "Forbidden. Your role does not have permission: \(resource):\(action)",
                    statusCode: 403
                )
                await emitAPIAudit(method: request.method, path: request.path, statusCode: 403)
                return response
            }
        }

        // Log tenant context for all authenticated API requests.
        logger.info("[\(self.tenantID.description, privacy: .public)] \(request.method, privacy: .public) \(request.path, privacy: .public)")

        if request.method == "GET" && request.path == "/metrics" {
            let response = await handleMetrics()
            await emitAPIAudit(method: request.method, path: request.path, statusCode: response.statusCode)
            return response
        }

        guard components.count >= 2,
              components[0] == "v1",
              components[1] == "vms"
        else {
            let response = HTTPResponse.error(message: "Not found.", statusCode: 404)
            await emitAPIAudit(method: request.method, path: request.path, statusCode: response.statusCode)
            return response
        }

        if components.count >= 3 {
            let vmName = components[2]
            guard vmName.wholeMatch(of: Self.vmNamePattern) != nil else {
                let response = HTTPResponse.error(message: "Invalid VM name.", statusCode: 400)
                await emitAPIAudit(method: request.method, path: request.path, statusCode: response.statusCode)
                return response
            }
        }

        let response: HTTPResponse
        switch (request.method, components.count) {
        case ("GET", 2):    response = handleListVMs()
        case ("POST", 2):   response = handleCreateVM(request)
        case ("GET", 3):    response = handleGetVM(name: components[2])
        case ("DELETE", 3): response = handleDeleteVM(name: components[2])
        case ("POST", 4) where components[3] == "clone": response = handleCloneVM(name: components[2], request: request)
        case ("POST", 4) where components[3] == "start": response = handleStartVM(name: components[2])
        case ("POST", 4) where components[3] == "stop":  response = handleStopVM(name: components[2])
        case ("GET", 4)  where components[3] == "ip":    response = await handleGetIP(name: components[2])
        default: response = HTTPResponse.error(message: "Not found.", statusCode: 404)
        }

        await emitAPIAudit(method: request.method, path: request.path, statusCode: response.statusCode)
        return response
    }

    /// Emits a structured audit record for an API request when an audit sink is configured.
    ///
    /// - Parameters:
    ///   - method: The HTTP method (e.g., `"GET"`, `"POST"`).
    ///   - path: The request path (e.g., `"/v1/vms/runner-1/start"`).
    ///   - statusCode: The HTTP status code of the response.
    /// Maps an API path to a resource type for RBAC evaluation.
    func inferResource(from path: String) -> String {
        if path.hasPrefix("/v1/vms") { return "vm" }
        if path.hasPrefix("/v1/audit") { return "audit" }
        if path == "/metrics" { return "metrics" }
        return "api"
    }

    /// Maps an HTTP method + path to an action for RBAC evaluation.
    func inferAction(from method: String, path: String) -> String {
        switch method {
        case "GET": return "list"
        case "POST":
            if path.hasSuffix("/clone") { return "create" }
            if path.hasSuffix("/start") { return "start" }
            if path.hasSuffix("/stop") { return "stop" }
            return "create"
        case "DELETE": return "delete"
        default: return "unknown"
        }
    }

    func emitAPIAudit(method: String, path: String, statusCode: Int) async {
        guard let sink = auditSink else { return }
        let record = AuditRecord(
            actorIdentity: "api-client",
            tenant: tenantID,
            scope: .admin,
            resource: path,
            action: method,
            outcome: statusCode < 400 ? .success : .failed
        )
        await sink.record(record)
    }

    // MARK: - Handlers

    /// Handles `GET /health`.
    ///
    /// Returns a simple health-check response confirming the server
    /// is running.
    private func handleHealth() -> HTTPResponse {
        HTTPResponse.ok(HealthResponse(service: "spooktacular", version: "0.1.0"))
    }

    /// Handles `GET /metrics`.
    ///
    /// Returns all collected metrics in Prometheus text exposition format
    /// (version 0.0.4). Requires authentication when `SPOOK_API_TOKEN`
    /// is set. Configure Prometheus with a Bearer token header.
    ///
    /// The response uses `Content-Type: text/plain; version=0.0.4; charset=utf-8`
    /// as required by the Prometheus specification.
    private func handleMetrics() async -> HTTPResponse {
        let text = await MetricsCollector.shared.prometheusText()
        return HTTPResponse.plainText(
            text,
            contentType: "text/plain; version=0.0.4; charset=utf-8"
        )
    }

    /// Handles `GET /v1/vms`.
    ///
    /// Lists all VM bundles in the VM directory with their
    /// configuration, metadata, and running state.
    private func handleListVMs() -> HTTPResponse {
        let fileManager = FileManager.default

        guard let contents = try? fileManager.contentsOfDirectory(
            at: vmDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return HTTPResponse.ok(VMListResponse(vms: []))
        }

        let bundles = contents
            .filter { $0.pathExtension == "vm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var vms: [VMStatus] = []
        for url in bundles {
            let name = url.deletingPathExtension().lastPathComponent
            guard let bundle = try? VirtualMachineBundle.load(from: url) else {
                continue
            }
            vms.append(vmStatus(name: name, bundle: bundle))
        }

        return HTTPResponse.ok(VMListResponse(vms: vms))
    }

    /// Handles `GET /v1/vms/:name`.
    ///
    /// Returns the full configuration and metadata for a single VM.
    private func handleGetVM(name: String) -> HTTPResponse {
        let bundleURL = SpooktacularPaths.bundleURL(for: name)

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' not found.", statusCode: 404)
        }

        guard let bundle = try? VirtualMachineBundle.load(from: bundleURL) else {
            return HTTPResponse.error(
                message: "VM '\(name)' has invalid configuration.",
                statusCode: 500
            )
        }

        return HTTPResponse.ok(vmStatus(name: name, bundle: bundle))
    }

    /// Handles `POST /v1/vms`.
    ///
    /// Creating a VM from scratch via the API is not supported because
    /// it requires an IPSW restore image and the full macOS install
    /// workflow. This endpoint returns a descriptive error directing
    /// the caller to use ``handleCloneVM(name:request:)`` instead, or
    /// the CLI for IPSW-based creation.
    private func handleCreateVM(_ request: HTTPRequest) -> HTTPResponse {
        logger.info("POST /v1/vms rejected — use clone or CLI instead")
        return HTTPResponse.error(
            message: "Use POST /v1/vms/:name/clone to create VMs from an existing base image, "
                + "or use the CLI: spook create <name> --from-ipsw latest",
            statusCode: 400
        )
    }

    /// Handles `POST /v1/vms/:name/clone`.
    ///
    /// Clones an existing base VM using APFS copy-on-write. This is the
    /// recommended workflow for programmatic VM creation: maintain a
    /// golden base image with macOS installed, then clone it for each
    /// runner or workspace.
    ///
    /// The clone receives a new `VZMacMachineIdentifier` so each VM
    /// has a unique hardware identity, as required by the Virtualization
    /// framework.
    ///
    /// Expected request body:
    /// ```json
    /// {"source": "base-vm"}
    /// ```
    ///
    /// - Parameters:
    ///   - name: The name for the new (cloned) VM.
    ///   - request: The HTTP request containing the JSON body.
    /// - Returns: An HTTP response with the cloned VM details (201)
    ///   or an error response.
    private func handleCloneVM(name: String, request: HTTPRequest) -> HTTPResponse {
        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse.error(message: "Request body required.", statusCode: 400)
        }

        struct CloneRequest: Decodable {
            let source: String
        }

        guard let cloneRequest = try? JSONDecoder().decode(CloneRequest.self, from: body),
              !cloneRequest.source.isEmpty else {
            return HTTPResponse.error(
                message: "Field 'source' is required. Provide the name of the base VM to clone.",
                statusCode: 400
            )
        }

        let sourceName = cloneRequest.source

        guard sourceName.wholeMatch(of: Self.vmNamePattern) != nil else {
            return HTTPResponse.error(message: "Invalid source VM name.", statusCode: 400)
        }

        let destinationURL = SpooktacularPaths.bundleURL(for: name)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' already exists.", statusCode: 409)
        }

        let sourceURL = SpooktacularPaths.bundleURL(for: sourceName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return HTTPResponse.error(message: "Source VM '\(sourceName)' not found.", statusCode: 404)
        }

        do {
            let sourceBundle = try VirtualMachineBundle.load(from: sourceURL)

            if PIDFile.isRunning(bundleURL: sourceURL) {
                return HTTPResponse.error(
                    message: "Source VM '\(sourceName)' is running. Stop it before cloning.",
                    statusCode: 409
                )
            }

            try SpooktacularPaths.ensureDirectories()
            let clonedBundle = try CloneManager.clone(source: sourceBundle, to: destinationURL)

            logger.notice("[\(self.tenantID.description, privacy: .public)] Cloned VM '\(sourceName, privacy: .public)' → '\(name, privacy: .public)' via API")
            return HTTPResponse.ok(vmStatus(name: name, bundle: clonedBundle), statusCode: 201)
        } catch {
            logger.error("Failed to clone VM '\(sourceName, privacy: .public)' → '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return HTTPResponse.error(
                message: "Failed to clone VM: \(error.localizedDescription)",
                statusCode: 500
            )
        }
    }

    /// Handles `POST /v1/vms/:name/start`.
    ///
    /// Starts a stopped VM by launching a detached `spook start`
    /// process in headless mode. The API does not hold the VM
    /// process -- it spawns it and returns immediately.
    ///
    /// The spawned process's stdout and stderr are redirected to
    /// `~/.spooktacular/logs/<vm-name>.log` for post-mortem
    /// debugging. The `spook` binary path is configured via the
    /// server's ``spookPath`` property rather than introspecting
    /// `ProcessInfo.processInfo.arguments[0]`, which is unreliable
    /// under launchd, Docker, or other non-standard deployments.
    private func handleStartVM(name: String) -> HTTPResponse {
        let bundleURL = SpooktacularPaths.bundleURL(for: name)

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' not found.", statusCode: 404)
        }

        if PIDFile.isRunning(bundleURL: bundleURL) {
            return HTTPResponse.error(message: "VM '\(name)' is already running.", statusCode: 409)
        }

        guard FileManager.default.isExecutableFile(atPath: spookPath) else {
            logger.error("spook binary not found at \(self.spookPath, privacy: .public)")
            return HTTPResponse.error(
                message: "spook binary not found at '\(spookPath)'. "
                    + "Set --spook-path or the SPOOK_PATH environment variable.",
                statusCode: 500
            )
        }

        let logsDirectory = SpooktacularPaths.root.appendingPathComponent("logs")
        do {
            try FileManager.default.createDirectory(
                at: logsDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("Failed to create logs directory: \(error.localizedDescription, privacy: .public)")
            return HTTPResponse.error(
                message: "Failed to create logs directory: \(error.localizedDescription)",
                statusCode: 500
            )
        }

        let logFileURL = logsDirectory.appendingPathComponent("\(name).log")
        let logFileHandle: FileHandle
        do {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            logFileHandle = try FileHandle(forWritingTo: logFileURL)
            logFileHandle.seekToEndOfFile()
        } catch {
            logger.error("Failed to open log file for VM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return HTTPResponse.error(
                message: "Failed to open log file: \(error.localizedDescription)",
                statusCode: 500
            )
        }

        let process = Process()
        process.executableURL = URL(filePath: spookPath)
        process.arguments = ["start", name, "--headless"]
        process.standardOutput = logFileHandle
        process.standardError = logFileHandle

        do {
            try process.run()
            logger.notice("[\(self.tenantID.description, privacy: .public)] Started VM '\(name, privacy: .public)' via API (PID \(process.processIdentifier), log: \(logFileURL.path, privacy: .public))")
            return HTTPResponse.ok(VMActionResponse(
                name: name,
                action: .start,
                pid: Int(process.processIdentifier),
                log: logFileURL.path
            ))
        } catch {
            logger.error("Failed to start VM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            try? logFileHandle.close()
            return HTTPResponse.error(
                message: "Failed to start VM: \(error.localizedDescription)",
                statusCode: 500
            )
        }
    }

    /// Handles `POST /v1/vms/:name/stop`.
    ///
    /// Sends `SIGTERM` to the process that owns the VM, triggering
    /// a graceful shutdown. Uses the same PID-file mechanism as
    /// `spook stop`.
    private func handleStopVM(name: String) -> HTTPResponse {
        let bundleURL = SpooktacularPaths.bundleURL(for: name)

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' not found.", statusCode: 404)
        }

        guard let pid = PIDFile.read(from: bundleURL) else {
            return HTTPResponse.error(message: "VM '\(name)' is not running.", statusCode: 409)
        }

        guard PIDFile.isProcessAlive(pid) else {
            PIDFile.remove(from: bundleURL)
            return HTTPResponse.error(message: "VM '\(name)' is not running (stale PID).", statusCode: 409)
        }

        let result = kill(pid, SIGTERM)
        if result == 0 {
            logger.notice("[\(self.tenantID.description, privacy: .public)] Sent SIGTERM to VM '\(name, privacy: .public)' (PID \(pid))")
            return HTTPResponse.ok(VMActionResponse(
                name: name,
                action: .stop,
                pid: Int(pid),
                log: nil
            ))
        } else {
            let errorCode = errno
            logger.error("Failed to send SIGTERM to PID \(pid): errno \(errorCode)")
            return HTTPResponse.error(
                message: "Failed to stop VM: signal failed with errno \(errorCode).",
                statusCode: 500
            )
        }
    }

    /// Handles `DELETE /v1/vms/:name`.
    ///
    /// Deletes a VM bundle and all its data. The VM must be stopped
    /// before deletion.
    private func handleDeleteVM(name: String) -> HTTPResponse {
        let bundleURL = SpooktacularPaths.bundleURL(for: name)

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' not found.", statusCode: 404)
        }

        if PIDFile.isRunning(bundleURL: bundleURL) {
            return HTTPResponse.error(
                message: "VM '\(name)' is running. Stop it before deleting.",
                statusCode: 409
            )
        }

        do {
            try FileManager.default.removeItem(at: bundleURL)
            logger.notice("[\(self.tenantID.description, privacy: .public)] Deleted VM '\(name, privacy: .public)' via API")
            return HTTPResponse.ok(VMDeleteResponse(name: name, deleted: true))
        } catch {
            logger.error("Failed to delete VM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return HTTPResponse.error(
                message: "Failed to delete VM: \(error.localizedDescription)",
                statusCode: 500
            )
        }
    }

    /// Handles `GET /v1/vms/:name/ip`.
    ///
    /// Resolves the IP address of a running VM by looking up its
    /// MAC address in the host's DHCP lease table and ARP cache.
    private func handleGetIP(name: String) async -> HTTPResponse {
        let bundleURL = SpooktacularPaths.bundleURL(for: name)

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' not found.", statusCode: 404)
        }

        guard PIDFile.isRunning(bundleURL: bundleURL) else {
            return HTTPResponse.error(message: "VM '\(name)' is not running.", statusCode: 409)
        }

        guard let bundle = try? VirtualMachineBundle.load(from: bundleURL) else {
            return HTTPResponse.error(
                message: "VM '\(name)' has invalid configuration.",
                statusCode: 500
            )
        }

        guard let macAddress = bundle.spec.macAddress else {
            return HTTPResponse.error(
                message: "VM '\(name)' has no configured MAC address.",
                statusCode: 422
            )
        }

        do {
            if let ip = try await IPResolver.resolveIP(macAddress: macAddress) {
                return HTTPResponse.ok(VMIPResponse(name: name, ip: ip, mac: macAddress.rawValue))
            } else {
                return HTTPResponse.error(
                    message: "Could not resolve IP for VM '\(name)'. The VM may still be booting.",
                    statusCode: 503
                )
            }
        } catch {
            return HTTPResponse.error(
                message: "IP resolution failed: \(error.localizedDescription)",
                statusCode: 500
            )
        }
    }

    // MARK: - Helpers

    /// Shared date formatter for API responses.
    private nonisolated(unsafe) static let iso8601Formatter = ISO8601DateFormatter()

    /// Converts a VM bundle into a typed ``VMStatus`` for JSON serialization.
    private func vmStatus(name: String, bundle: VirtualMachineBundle) -> VMStatus {
        let spec = bundle.spec
        let metadata = bundle.metadata

        return VMStatus(
            name: name,
            running: PIDFile.isRunning(bundleURL: bundle.url),
            cpu: spec.cpuCount,
            memorySizeInGigabytes: spec.memorySizeInGigabytes,
            diskSizeInGigabytes: spec.diskSizeInGigabytes,
            displays: spec.displayCount,
            network: spec.networkMode,
            audio: spec.audioEnabled,
            microphone: spec.microphoneEnabled,
            macAddress: spec.macAddress?.rawValue,
            setupCompleted: metadata.setupCompleted,
            id: metadata.id,
            createdAt: metadata.createdAt,
            path: bundle.url.path
        )
    }
}

// MARK: - Errors

/// Errors that can occur during HTTP API server operation.
public enum HTTPAPIServerError: Error, Sendable, LocalizedError {

    /// The HTTP request data could not be parsed.
    case malformedRequest

    /// The server was cancelled before it started.
    case cancelled

    /// The port is already in use.
    case portInUse(UInt16)

    /// The port number is invalid (e.g., 0).
    case invalidPort(UInt16)

    /// No API token is configured and the server is not running in
    /// insecure mode. An API token is required to prevent
    /// unauthorized access to VM management endpoints.
    case missingAPIToken

    /// The TLS certificate file could not be opened for monitoring.
    case certificateFileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .malformedRequest:
            "Malformed HTTP request."
        case .cancelled:
            "Server was cancelled."
        case .portInUse(let port):
            "Port \(port) is already in use."
        case .invalidPort(let port):
            "Invalid port number: \(port)."
        case .missingAPIToken:
            "No API token configured."
        case .certificateFileNotFound(let path):
            "TLS certificate file not found at '\(path)'."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedRequest:
            "Ensure the HTTP request is well-formed with valid headers and body."
        case .cancelled:
            "Restart the server with 'spook serve'."
        case .portInUse:
            "Choose a different port with --port, or stop the process using the current port."
        case .invalidPort:
            "Use a port number between 1 and 65535."
        case .missingAPIToken:
            "Set the SPOOK_API_TOKEN environment variable, provide TLS certificates with --tls-cert and --tls-key, or use --insecure to bypass (not recommended for production)."
        case .certificateFileNotFound:
            "Ensure the certificate file path is correct and the file exists."
        }
    }
}
