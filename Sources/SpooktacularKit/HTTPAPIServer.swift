import Foundation
import Network
import os

// MARK: - HTTP API Server

/// A lightweight HTTP API server for managing virtual machines programmatically.
///
/// `HTTPAPIServer` provides a RESTful JSON API over plain HTTP, built on
/// Apple's `Network.framework` (`NWListener`). It exposes endpoints for
/// listing, creating, starting, stopping, and deleting VMs, as well as
/// resolving VM IP addresses and performing health checks.
///
/// The server binds to localhost by default and does **not** provide TLS
/// or authentication. Use a reverse proxy (e.g., Caddy, nginx) for
/// production deployments that require encryption or access control.
///
/// ## Endpoints
///
/// | Method | Path | Description |
/// |--------|------|-------------|
/// | `GET` | `/health` | Health check |
/// | `GET` | `/v1/vms` | List all VMs |
/// | `GET` | `/v1/vms/:name` | Get VM details |
/// | `POST` | `/v1/vms` | Create a new VM |
/// | `POST` | `/v1/vms/:name/start` | Start a VM |
/// | `POST` | `/v1/vms/:name/stop` | Stop a VM |
/// | `DELETE` | `/v1/vms/:name` | Delete a VM |
/// | `GET` | `/v1/vms/:name/ip` | Resolve VM IP address |
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
/// let server = try HTTPAPIServer(host: "127.0.0.1", port: 8484, vmDirectory: Paths.vms)
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

    // MARK: - Properties

    /// The NWListener that accepts incoming TCP connections.
    private let listener: NWListener

    /// The directory containing `.vm` bundle directories.
    private let vmDirectory: URL

    /// Logger for HTTP API events.
    private let logger = Logger(subsystem: "com.spooktacular", category: "http-api")

    /// Tracks whether the server is currently running.
    private var isRunning = false

    /// Active connections tracked for clean shutdown.
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]

    // MARK: - Initialization

    /// Creates a new HTTP API server.
    ///
    /// - Parameters:
    ///   - host: The hostname or IP address to bind to. Defaults to
    ///     `"127.0.0.1"` (localhost only).
    ///   - port: The TCP port to listen on. Defaults to `8484`.
    ///   - vmDirectory: The directory containing VM bundles
    ///     (typically `~/.spooktacular/vms/`).
    /// - Throws: `NWError` if the listener cannot be created.
    public init(host: String, port: UInt16, vmDirectory: URL) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        self.listener = try NWListener(using: parameters)
        self.vmDirectory = vmDirectory
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

        listener.stateUpdateHandler = { [logger] state in
            switch state {
            case .ready:
                logger.notice("HTTP API server is ready and listening")
            case .failed(let error):
                logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
            case .cancelled:
                logger.notice("Listener cancelled")
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task {
                await self.handleNewConnection(connection)
            }
        }

        listener.start(queue: .global(qos: .userInitiated))

        // Wait until the listener transitions to .ready or fails.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { [logger] state in
                switch state {
                case .ready:
                    logger.notice("HTTP API server is ready and listening")
                    continuation.resume()
                case .failed(let error):
                    logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                case .cancelled:
                    logger.notice("Listener cancelled")
                    continuation.resume(throwing: HTTPAPIServerError.cancelled)
                default:
                    break
                }
            }
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

    // MARK: - Connection Handling

    /// Accepts a new TCP connection and processes HTTP requests on it.
    private func handleNewConnection(_ connection: NWConnection) {
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

    /// Removes a connection from the active set.
    private func removeConnection(_ connection: NWConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    /// Reads data from a connection until a complete HTTP request is received.
    private nonisolated func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                if isComplete || error != nil {
                    connection.cancel()
                }
                return
            }

            Task {
                await self.processReceivedData(data, on: connection)
            }
        }
    }

    /// Processes received data, parsing the HTTP request and dispatching to handlers.
    private func processReceivedData(_ data: Data, on connection: NWConnection) async {
        let request: HTTPRequest
        do {
            request = try HTTPRequestParser.parse(data)
        } catch {
            logger.debug("Failed to parse HTTP request: \(error.localizedDescription, privacy: .public)")
            let response = HTTPResponse.error(message: "Malformed HTTP request.", statusCode: 400)
            sendResponse(response, on: connection)
            return
        }

        logger.info("\(request.method, privacy: .public) \(request.path, privacy: .public)")

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

    /// Routes an HTTP request to the appropriate handler based on method and path.
    ///
    /// Path matching uses simple prefix/component matching:
    /// - `/health` -- health check
    /// - `/v1/vms` -- list or create VMs
    /// - `/v1/vms/:name` -- get or delete a specific VM
    /// - `/v1/vms/:name/start` -- start a VM
    /// - `/v1/vms/:name/stop` -- stop a VM
    /// - `/v1/vms/:name/ip` -- resolve VM IP
    private func routeRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let components = request.path
            .split(separator: "/")
            .map(String.init)

        // GET /health
        if request.method == "GET" && request.path == "/health" {
            return handleHealth()
        }

        // /v1/vms routes
        guard components.count >= 2,
              components[0] == "v1",
              components[1] == "vms"
        else {
            return HTTPResponse.error(message: "Not found.", statusCode: 404)
        }

        switch (request.method, components.count) {
        // GET /v1/vms
        case ("GET", 2):
            return handleListVMs()

        // POST /v1/vms
        case ("POST", 2):
            return await handleCreateVM(request)

        // GET /v1/vms/:name
        case ("GET", 3):
            return handleGetVM(name: components[2])

        // DELETE /v1/vms/:name
        case ("DELETE", 3):
            return handleDeleteVM(name: components[2])

        // POST /v1/vms/:name/start
        case ("POST", 4) where components[3] == "start":
            return handleStartVM(name: components[2])

        // POST /v1/vms/:name/stop
        case ("POST", 4) where components[3] == "stop":
            return handleStopVM(name: components[2])

        // GET /v1/vms/:name/ip
        case ("GET", 4) where components[3] == "ip":
            return await handleGetIP(name: components[2])

        default:
            return HTTPResponse.error(message: "Not found.", statusCode: 404)
        }
    }

    // MARK: - Handlers

    /// Handles `GET /health`.
    ///
    /// Returns a simple health-check response confirming the server
    /// is running.
    private func handleHealth() -> HTTPResponse {
        HTTPResponse.ok(data: ["service": "spooktacular", "version": "0.1.0"])
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
            return HTTPResponse.ok(data: ["vms": [Any]()])
        }

        let bundles = contents
            .filter { $0.pathExtension == "vm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var vms: [[String: Any]] = []
        for url in bundles {
            let name = url.deletingPathExtension().lastPathComponent
            guard let bundle = try? VirtualMachineBundle.load(from: url) else {
                continue
            }
            vms.append(vmToDict(name: name, bundle: bundle))
        }

        return HTTPResponse.ok(data: ["vms": vms])
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

        return HTTPResponse.ok(data: vmToDict(name: name, bundle: bundle))
    }

    /// Handles `POST /v1/vms`.
    ///
    /// Creates a new VM bundle with the specification provided in the
    /// request body. This endpoint creates the bundle directory and
    /// configuration files but does **not** install macOS or create a
    /// disk image -- those require the full `spook create` workflow.
    ///
    /// Expected request body:
    /// ```json
    /// {
    ///     "name": "my-vm",
    ///     "cpu": 4,
    ///     "memory": 8,
    ///     "disk": 64,
    ///     "displays": 1,
    ///     "network": "nat"
    /// }
    /// ```
    private func handleCreateVM(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body, !body.isEmpty else {
            return HTTPResponse.error(message: "Request body required.", statusCode: 400)
        }

        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return HTTPResponse.error(message: "Invalid JSON in request body.", statusCode: 400)
        }

        guard let name = json["name"] as? String, !name.isEmpty else {
            return HTTPResponse.error(message: "Field 'name' is required.", statusCode: 400)
        }

        let bundleURL = SpooktacularPaths.bundleURL(for: name)
        guard !FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' already exists.", statusCode: 409)
        }

        let cpu = json["cpu"] as? Int ?? 4
        let memory = json["memory"] as? Int ?? 8
        let disk = json["disk"] as? Int ?? 64
        let displays = json["displays"] as? Int ?? 1
        let networkString = json["network"] as? String ?? "nat"

        let networkMode: NetworkMode
        switch networkString {
        case "nat":
            networkMode = .nat
        case "isolated":
            networkMode = .isolated
        case let s where s.hasPrefix("bridged:"):
            let interface = String(s.dropFirst("bridged:".count))
            networkMode = .bridged(interface: interface)
        default:
            return HTTPResponse.error(
                message: "Invalid network mode '\(networkString)'. Use 'nat', 'isolated', or 'bridged:<interface>'.",
                statusCode: 400
            )
        }

        let spec = VirtualMachineSpecification(
            cpuCount: cpu,
            memorySizeInBytes: UInt64(memory) * 1024 * 1024 * 1024,
            diskSizeInBytes: UInt64(disk) * 1024 * 1024 * 1024,
            displayCount: displays,
            networkMode: networkMode
        )

        do {
            try SpooktacularPaths.ensureDirectories()
            let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)
            logger.notice("Created VM '\(name, privacy: .public)' via API")
            return HTTPResponse(
                statusCode: 201,
                body: HTTPResponse.envelope(
                    status: "ok",
                    data: vmToDict(name: name, bundle: bundle)
                )
            )
        } catch {
            logger.error("Failed to create VM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return HTTPResponse.error(
                message: "Failed to create VM: \(error.localizedDescription)",
                statusCode: 500
            )
        }
    }

    /// Handles `POST /v1/vms/:name/start`.
    ///
    /// Starts a stopped VM by launching a detached `spook start`
    /// process in headless mode. The API does not hold the VM
    /// process -- it spawns it and returns immediately.
    private func handleStartVM(name: String) -> HTTPResponse {
        let bundleURL = SpooktacularPaths.bundleURL(for: name)

        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            return HTTPResponse.error(message: "VM '\(name)' not found.", statusCode: 404)
        }

        if PIDFile.isRunning(bundleURL: bundleURL) {
            return HTTPResponse.error(message: "VM '\(name)' is already running.", statusCode: 409)
        }

        // Locate the spook executable to spawn a headless start.
        let executablePath = ProcessInfo.processInfo.arguments[0]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["start", name, "--headless"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            logger.notice("Started VM '\(name, privacy: .public)' via API (PID \(process.processIdentifier))")
            return HTTPResponse.ok(data: [
                "name": name,
                "action": "start",
                "pid": Int(process.processIdentifier),
            ] as [String: Any])
        } catch {
            logger.error("Failed to start VM '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
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
            logger.notice("Sent SIGTERM to VM '\(name, privacy: .public)' (PID \(pid))")
            return HTTPResponse.ok(data: [
                "name": name,
                "action": "stop",
                "pid": Int(pid),
            ] as [String: Any])
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
            logger.notice("Deleted VM '\(name, privacy: .public)' via API")
            return HTTPResponse.ok(data: ["name": name, "deleted": true])
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
                return HTTPResponse.ok(data: ["name": name, "ip": ip, "mac": macAddress])
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

    /// Converts a VM bundle into a dictionary suitable for JSON serialization.
    private func vmToDict(name: String, bundle: VirtualMachineBundle) -> [String: Any] {
        let spec = bundle.spec
        let metadata = bundle.metadata
        let isRunning = PIDFile.isRunning(bundleURL: bundle.url)

        var network: String
        switch spec.networkMode {
        case .nat: network = "nat"
        case .bridged(let interface): network = "bridged:\(interface)"
        case .isolated: network = "isolated"
        }

        return [
            "name": name,
            "running": isRunning,
            "cpu": spec.cpuCount,
            "memorySizeInGigabytes": spec.memorySizeInGigabytes,
            "diskSizeInGigabytes": spec.diskSizeInGigabytes,
            "displays": spec.displayCount,
            "network": network,
            "audio": spec.audioEnabled,
            "microphone": spec.microphoneEnabled,
            "macAddress": spec.macAddress as Any,
            "setupCompleted": metadata.setupCompleted,
            "id": metadata.id.uuidString,
            "createdAt": ISO8601DateFormatter().string(from: metadata.createdAt),
            "path": bundle.url.path,
        ]
    }
}

// MARK: - HTTP Request

/// A parsed HTTP request.
///
/// Contains the essential parts of an HTTP/1.1 request: the method,
/// path, headers, and optional body. Only the headers needed for
/// API routing (`Content-Length`, `Content-Type`) are parsed.
struct HTTPRequest: Sendable {

    /// The HTTP method (e.g., `"GET"`, `"POST"`, `"DELETE"`).
    let method: String

    /// The request path (e.g., `"/v1/vms"`).
    let path: String

    /// Parsed HTTP headers as key-value pairs. Keys are lowercased.
    let headers: [String: String]

    /// The request body, if present.
    let body: Data?
}

// MARK: - HTTP Request Parser

/// A minimal HTTP/1.1 request parser.
///
/// Parses the request line, headers, and body from raw TCP data.
/// This parser handles the subset of HTTP needed for the API:
/// - Request line: `METHOD /path HTTP/1.1`
/// - Headers: `Content-Length` and `Content-Type`
/// - Body: read based on `Content-Length`
///
/// It does not support chunked transfer encoding, HTTP/2,
/// keep-alive, or any advanced HTTP features.
enum HTTPRequestParser {

    /// Parses raw TCP data into an ``HTTPRequest``.
    ///
    /// - Parameter data: The raw bytes received from the TCP connection.
    /// - Returns: A parsed HTTP request.
    /// - Throws: ``HTTPAPIServerError/malformedRequest`` if the data
    ///   cannot be parsed as a valid HTTP request.
    static func parse(_ data: Data) throws -> HTTPRequest {
        guard let string = String(data: data, encoding: .utf8) else {
            throw HTTPAPIServerError.malformedRequest
        }

        // Split headers from body at the blank line.
        let parts = string.components(separatedBy: "\r\n\r\n")
        guard let headerSection = parts.first else {
            throw HTTPAPIServerError.malformedRequest
        }

        var lines = headerSection.components(separatedBy: "\r\n")

        // Parse the request line: "GET /path HTTP/1.1"
        guard let requestLine = lines.first else {
            throw HTTPAPIServerError.malformedRequest
        }
        lines.removeFirst()

        let requestParts = requestLine.split(separator: " ", maxSplits: 2)
        guard requestParts.count >= 2 else {
            throw HTTPAPIServerError.malformedRequest
        }

        let method = String(requestParts[0])
        let rawPath = String(requestParts[1])

        // Strip query string if present.
        let path: String
        if let queryIndex = rawPath.firstIndex(of: "?") {
            path = String(rawPath[rawPath.startIndex..<queryIndex])
        } else {
            path = rawPath
        }

        // Parse headers.
        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colonIndex]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colonIndex)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // Extract body if Content-Length is present.
        var body: Data?
        if parts.count > 1 {
            let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
            if !bodyString.isEmpty {
                body = bodyString.data(using: .utf8)
            }
        }

        return HTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: body
        )
    }
}

// MARK: - HTTP Response

/// An HTTP response with status code, headers, and JSON body.
///
/// Serializes to a complete HTTP/1.1 response including the status
/// line, headers (`Content-Type`, `Content-Length`,
/// `Connection: close`), and body. The body is always JSON.
struct HTTPResponse: Sendable {

    /// The HTTP status code (e.g., 200, 404, 500).
    let statusCode: Int

    /// The JSON response body as raw bytes.
    let body: Data

    /// The HTTP status text for common status codes.
    private var statusText: String {
        switch statusCode {
        case 200: "OK"
        case 201: "Created"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 409: "Conflict"
        case 422: "Unprocessable Entity"
        case 500: "Internal Server Error"
        case 503: "Service Unavailable"
        default: "Unknown"
        }
    }

    /// Serializes the response to raw HTTP/1.1 bytes.
    ///
    /// Produces a complete HTTP response including the status line,
    /// `Content-Type`, `Content-Length`, and `Connection` headers,
    /// followed by the JSON body.
    ///
    /// - Returns: The serialized HTTP response as `Data`.
    func serialize() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        response += "Content-Type: application/json; charset=utf-8\r\n"
        response += "Content-Length: \(body.count)\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    /// Creates a JSON envelope with the given status and data.
    ///
    /// - Parameters:
    ///   - status: The status string (`"ok"` or `"error"`).
    ///   - data: The data payload dictionary.
    /// - Returns: The serialized JSON envelope as `Data`.
    static func envelope(status: String, data: Any) -> Data {
        let envelope: [String: Any] = ["status": status, "data": data]
        return (try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
    }

    /// Creates an error envelope.
    ///
    /// - Parameters:
    ///   - status: The status string (always `"error"`).
    ///   - message: The error message.
    /// - Returns: The serialized JSON error envelope as `Data`.
    static func errorEnvelope(message: String) -> Data {
        let envelope: [String: Any] = ["status": "error", "message": message]
        return (try? JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
    }

    /// Creates a success response with data.
    ///
    /// - Parameters:
    ///   - data: The response data payload.
    ///   - statusCode: The HTTP status code. Defaults to 200.
    /// - Returns: A success HTTP response.
    static func ok(data: Any, statusCode: Int = 200) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            body: envelope(status: "ok", data: data)
        )
    }

    /// Creates an error response.
    ///
    /// - Parameters:
    ///   - message: A human-readable error description.
    ///   - statusCode: The HTTP status code.
    /// - Returns: An error HTTP response.
    static func error(message: String, statusCode: Int) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            body: errorEnvelope(message: message)
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

    public var errorDescription: String? {
        switch self {
        case .malformedRequest:
            "Malformed HTTP request."
        case .cancelled:
            "Server was cancelled."
        case .portInUse(let port):
            "Port \(port) is already in use."
        }
    }
}
