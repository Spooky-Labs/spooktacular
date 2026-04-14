/// Endpoint routing and handler implementations for the spooktacular-agent HTTP API.
///
/// The router dispatches incoming ``AgentHTTPRequest`` values to free-function
/// handlers based on the HTTP method and path. Each handler follows the
/// Interactor pattern from Clean Architecture: it receives a request,
/// performs business logic, and returns a serialized HTTP response.
///
/// ## Endpoints
///
/// | Method | Path | Handler |
/// |--------|------|---------|
/// | `GET` | `/health` | ``handleHealth()`` |
/// | `GET` | `/api/v1/clipboard` | ``handleGetClipboard()`` |
/// | `POST` | `/api/v1/clipboard` | ``handleSetClipboard(_:)`` |
/// | `POST` | `/api/v1/exec` | ``handleExec(_:)`` (admin only) |
/// | `GET` | `/api/v1/apps` | ``handleListApps()`` |
/// | `POST` | `/api/v1/apps/launch` | ``handleLaunchApp(_:)`` |
/// | `POST` | `/api/v1/apps/quit` | ``handleQuitApp(_:)`` |
/// | `GET` | `/api/v1/apps/frontmost` | ``handleFrontmostApp()`` |
/// | `GET` | `/api/v1/fs` | ``handleListFS(_:)`` |
/// | `POST` | `/api/v1/files` | ``handleUploadFile(_:)`` |
/// | `GET` | `/api/v1/files` | ``handleListFiles()`` |
/// | `GET` | `/api/v1/ports` | ``handleListPorts()`` |

import AppKit
import Foundation
import os

/// Logger for agent route handlers.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "router")

/// Logger dedicated to the audit trail, visible in Console.app at `.notice` level.
private let auditLog = Logger(subsystem: "com.spooktacular.agent", category: "audit")

/// The agent version, reported in health checks.
private let agentVersion = "1.0.0"

/// The process start time, used to compute uptime.
private let agentStartTime = Date()

/// Shared JSON encoder with sorted keys for deterministic output.
private let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}()

/// Shared JSON decoder.
private let jsonDecoder = JSONDecoder()

// MARK: - Authorization Scope

/// The authorization scope required by an endpoint.
///
/// Three-tier model:
/// - ``readonly``: GET endpoints that inspect state without mutating it.
/// - ``runner``: Mutation endpoints except exec (launch/quit apps, set clipboard, upload files).
/// - ``admin``: Break-glass scope that includes exec and everything else.
private enum EndpointScope: String {
    /// Read-only endpoints that inspect state without mutating it.
    case readonly
    /// Runner-level mutation endpoints (apps, clipboard, files) — excludes exec.
    case runner
    /// Admin (break-glass) endpoints — everything including exec.
    case admin
}

/// Returns the ``EndpointScope`` for the given method/path pair,
/// or `nil` if the route is unknown.
private func endpointScope(method: String, path: String) -> EndpointScope? {
    switch (method, path) {
    // Admin — break-glass scope (exec)
    case ("POST", "/api/v1/exec"):
        return .admin
    // Runner — mutation except exec
    case ("POST", "/api/v1/clipboard"),
         ("POST", "/api/v1/apps/launch"),
         ("POST", "/api/v1/apps/quit"),
         ("POST", "/api/v1/files"):
        return .runner
    // Read-only — basic scope
    case ("GET", "/health"),
         ("GET", "/api/v1/clipboard"),
         ("GET", "/api/v1/apps"),
         ("GET", "/api/v1/apps/frontmost"),
         ("GET", "/api/v1/fs"),
         ("GET", "/api/v1/files"),
         ("GET", "/api/v1/ports"):
        return .readonly
    default:
        return nil
    }
}

// MARK: - Router

/// The authorization tier determined from the presented Bearer token.
///
/// Used to enforce scope-based access control and to annotate audit log entries.
private enum AuthTier: String {
    /// Admin (break-glass) — all endpoints including exec.
    case admin
    /// Runner — mutation endpoints except exec.
    case runner
    /// Read-only — GET endpoints only.
    case readonly
    /// Legacy mode — no tokens configured, all endpoints allowed.
    case legacy
}

/// Routes an ``AgentHTTPRequest`` to the appropriate handler.
///
/// When any token is configured the router enforces Bearer-token
/// authentication with three-tier scope-based authorization:
///
/// - **Admin token**: Grants access to all endpoints including exec (break-glass).
/// - **Runner token**: Grants access to read-only and mutation endpoints,
///   but NOT exec. Exec returns 403 Forbidden.
/// - **Read-only token**: Grants access to read-only endpoints only.
///   Mutation and exec endpoints return 403 Forbidden.
///
/// If no token is configured the agent runs in legacy mode
/// (no auth, warning already logged at startup).
///
/// After dispatching every request the router emits an audit-level log
/// entry via `os.Logger` at `.notice` so it appears in Console.app.
/// The log includes the resolved authorization tier.
///
/// - Parameters:
///   - request: The parsed HTTP request.
///   - adminToken: The admin (break-glass) Bearer token, or `nil` for legacy mode.
///   - runnerToken: The runner Bearer token, or `nil` if not configured.
///   - readonlyToken: The read-only Bearer token, or `nil` if not configured.
/// - Returns: A complete HTTP/1.1 response as raw bytes.
func routeRequest(
    _ request: AgentHTTPRequest,
    adminToken: String? = nil,
    runnerToken: String? = nil,
    readonlyToken: String? = nil
) -> Data {

    // --- Auth gate ---
    let hasAnyToken = adminToken != nil || runnerToken != nil || readonlyToken != nil
    let authTier: AuthTier

    if hasAnyToken {
        let authHeader = request.headers["authorization"] ?? ""

        // Determine which token was presented
        let isAdmin = adminToken != nil && authHeader == "Bearer \(adminToken!)"
        let isRunner = runnerToken != nil && authHeader == "Bearer \(runnerToken!)"
        let isReadOnly = readonlyToken != nil && authHeader == "Bearer \(readonlyToken!)"

        if isAdmin {
            authTier = .admin
        } else if isRunner {
            authTier = .runner
        } else if isReadOnly {
            authTier = .readonly
        } else {
            let response = errorResponse(message: "Unauthorized.", statusCode: 401)
            emitAuditLog(method: request.method, path: request.path, statusCode: 401, tier: nil)
            return response
        }

        // Enforce scope restrictions
        let scope = endpointScope(method: request.method, path: request.path)
        switch authTier {
        case .readonly:
            if scope == .runner || scope == .admin {
                let response = errorResponse(
                    message: "Forbidden. Read-only token cannot access mutation endpoints.",
                    statusCode: 403
                )
                emitAuditLog(method: request.method, path: request.path, statusCode: 403, tier: authTier)
                return response
            }
        case .runner:
            if scope == .admin {
                let response = errorResponse(
                    message: "Forbidden. Runner token cannot access admin endpoints.",
                    statusCode: 403
                )
                emitAuditLog(method: request.method, path: request.path, statusCode: 403, tier: authTier)
                return response
            }
        case .admin, .legacy:
            break // Admin and legacy allow everything
        }
    } else {
        authTier = .legacy
    }

    // --- Dispatch ---
    let response: Data
    let statusCode: Int

    switch (request.method, request.path) {
    case ("GET", "/health"):
        response = handleHealth()
        statusCode = 200
    case ("GET", "/api/v1/clipboard"):
        response = handleGetClipboard()
        statusCode = 200
    case ("POST", "/api/v1/clipboard"):
        response = handleSetClipboard(request)
        statusCode = 200
    case ("POST", "/api/v1/exec"):
        response = handleExec(request)
        statusCode = 200
    case ("GET", "/api/v1/apps"):
        response = handleListApps()
        statusCode = 200
    case ("POST", "/api/v1/apps/launch"):
        response = handleLaunchApp(request)
        statusCode = 200
    case ("POST", "/api/v1/apps/quit"):
        response = handleQuitApp(request)
        statusCode = 200
    case ("GET", "/api/v1/apps/frontmost"):
        response = handleFrontmostApp()
        statusCode = 200
    case ("GET", "/api/v1/fs"):
        response = handleListFS(request)
        statusCode = 200
    case ("POST", "/api/v1/files"):
        response = handleUploadFile(request)
        statusCode = 201
    case ("GET", "/api/v1/files"):
        response = handleListFiles()
        statusCode = 200
    case ("GET", "/api/v1/ports"):
        response = handleListPorts()
        statusCode = 200
    default:
        response = errorResponse(message: "Not found.", statusCode: 404)
        statusCode = 404
    }

    emitAuditLog(method: request.method, path: request.path, statusCode: statusCode, tier: authTier)
    return response
}

/// Emits an audit log entry at `.notice` level.
///
/// The message includes the resolved authorization tier and an ISO-8601
/// timestamp so the audit trail is self-contained even when log
/// timestamps are stripped.
///
/// - Parameters:
///   - method: The HTTP method (e.g., `"GET"`).
///   - path: The request path (e.g., `"/api/v1/exec"`).
///   - statusCode: The HTTP status code of the response.
///   - tier: The authorization tier that handled this request, or `nil` for unauthenticated.
private func emitAuditLog(method: String, path: String, statusCode: Int, tier: AuthTier?) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let tierLabel = tier?.rawValue ?? "none"
    auditLog.notice("AUDIT: \(method, privacy: .public) \(path, privacy: .public) → \(statusCode) [\(tierLabel, privacy: .public)] [\(timestamp, privacy: .public)]")
}

// MARK: - Response Builders

/// Builds an HTTP 200 response with a JSON-encoded body.
///
/// - Parameters:
///   - data: The `Encodable` value to serialize as JSON.
///   - statusCode: The HTTP status code. Defaults to 200.
/// - Returns: A complete HTTP/1.1 response as raw bytes.
private func jsonResponse<T: Encodable>(_ data: T, statusCode: Int = 200) -> Data {
    let body = (try? jsonEncoder.encode(data)) ?? Data("{}".utf8)
    return buildHTTPResponse(statusCode: statusCode, body: body)
}

/// Builds an HTTP error response with a JSON `{"error": "..."}` body.
///
/// - Parameters:
///   - message: The human-readable error message.
///   - statusCode: The HTTP status code (e.g., 400, 404, 500).
/// - Returns: A complete HTTP/1.1 response as raw bytes.
private func errorResponse(message: String, statusCode: Int) -> Data {
    struct ErrorBody: Encodable { let error: String }
    let body = (try? jsonEncoder.encode(ErrorBody(error: message))) ?? Data("{}".utf8)
    return buildHTTPResponse(statusCode: statusCode, body: body)
}

/// Assembles a raw HTTP/1.1 response from a status code and JSON body.
///
/// - Parameters:
///   - statusCode: The HTTP status code.
///   - body: The response body bytes.
/// - Returns: The full HTTP response including status line, headers, and body.
private func buildHTTPResponse(statusCode: Int, body: Data) -> Data {
    let statusText: String
    switch statusCode {
    case 200: statusText = "OK"
    case 201: statusText = "Created"
    case 400: statusText = "Bad Request"
    case 401: statusText = "Unauthorized"
    case 403: statusText = "Forbidden"
    case 404: statusText = "Not Found"
    case 500: statusText = "Internal Server Error"
    default:  statusText = "Unknown"
    }

    var header = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
    header += "Content-Type: application/json; charset=utf-8\r\n"
    header += "Content-Length: \(body.count)\r\n"
    header += "Connection: close\r\n"
    header += "\r\n"

    var response = Data(header.utf8)
    response.append(body)
    return response
}

// MARK: - Health

/// Handles `GET /health`.
///
/// Returns the agent version and uptime in seconds.
private func handleHealth() -> Data {
    let uptime = Date().timeIntervalSince(agentStartTime)
    let health = HealthResponse(status: "ok", version: agentVersion, uptime: uptime)
    return jsonResponse(health)
}

// MARK: - Clipboard

/// Handles `GET /api/v1/clipboard`.
///
/// Reads the current plain-text content from the macOS general
/// pasteboard via `NSPasteboard`.
private func handleGetClipboard() -> Data {
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    return jsonResponse(ClipboardContent(text: text))
}

/// Handles `POST /api/v1/clipboard`.
///
/// Sets the macOS general pasteboard to the provided text.
///
/// - Parameter request: Must contain a JSON body with a `text` field.
private func handleSetClipboard(_ request: AgentHTTPRequest) -> Data {
    guard let body = request.body,
          let content = try? jsonDecoder.decode(ClipboardContent.self, from: body) else {
        return errorResponse(message: "Request body must contain 'text' field.", statusCode: 400)
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(content.text, forType: .string)
    return jsonResponse(content)
}

// MARK: - Exec

/// Handles `POST /api/v1/exec`.
///
/// Runs a shell command via `/bin/bash -c` and captures stdout,
/// stderr, and the exit code. An optional timeout (in seconds)
/// terminates the process if it exceeds the limit.
///
/// - Parameter request: Must contain a JSON body with a `command` field.
private func handleExec(_ request: AgentHTTPRequest) -> Data {
    guard let body = request.body,
          let execReq = try? jsonDecoder.decode(ExecRequest.self, from: body) else {
        return errorResponse(message: "Request body must contain 'command' field.", statusCode: 400)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", execReq.command]

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        log.error("Failed to launch command: \(error.localizedDescription, privacy: .public)")
        return errorResponse(message: "Failed to launch command: \(error.localizedDescription)", statusCode: 500)
    }

    let timeout = execReq.timeout ?? 30
    let deadline = DispatchTime.now() + .seconds(timeout)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async {
        process.waitUntilExit()
        group.leave()
    }

    if group.wait(timeout: deadline) == .timedOut {
        process.terminate()
        process.waitUntilExit()
        return errorResponse(message: "Command timed out after \(timeout) seconds.", statusCode: 500)
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

    let response = ExecResponse(
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
    return jsonResponse(response)
}

// MARK: - Apps

/// Handles `GET /api/v1/apps`.
///
/// Lists all running applications visible to `NSWorkspace`.
private func handleListApps() -> Data {
    let frontmost = NSWorkspace.shared.frontmostApplication
    let apps = NSWorkspace.shared.runningApplications.compactMap { app -> AppInfo? in
        guard let name = app.localizedName,
              let bundleID = app.bundleIdentifier else { return nil }
        return AppInfo(
            name: name,
            bundleID: bundleID,
            isActive: app.processIdentifier == frontmost?.processIdentifier,
            pid: app.processIdentifier
        )
    }
    return jsonResponse(apps)
}

/// Handles `POST /api/v1/apps/launch`.
///
/// Launches an application by its bundle identifier using `NSWorkspace`.
///
/// - Parameter request: Must contain a JSON body with a `bundleID` field.
private func handleLaunchApp(_ request: AgentHTTPRequest) -> Data {
    guard let body = request.body,
          let appReq = try? jsonDecoder.decode(AppRequest.self, from: body) else {
        return errorResponse(message: "Request body must contain 'bundleID' field.", statusCode: 400)
    }

    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appReq.bundleID) else {
        return errorResponse(message: "Application '\(appReq.bundleID)' not found.", statusCode: 404)
    }

    let config = NSWorkspace.OpenConfiguration()
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var launchError: (any Error)?

    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        launchError = error
        semaphore.signal()
    }
    semaphore.wait()

    if let error = launchError {
        return errorResponse(message: "Failed to launch: \(error.localizedDescription)", statusCode: 500)
    }

    struct LaunchResult: Encodable { let launched: Bool; let bundleID: String }
    return jsonResponse(LaunchResult(launched: true, bundleID: appReq.bundleID))
}

/// Handles `POST /api/v1/apps/quit`.
///
/// Terminates a running application by its bundle identifier.
///
/// - Parameter request: Must contain a JSON body with a `bundleID` field.
private func handleQuitApp(_ request: AgentHTTPRequest) -> Data {
    guard let body = request.body,
          let appReq = try? jsonDecoder.decode(AppRequest.self, from: body) else {
        return errorResponse(message: "Request body must contain 'bundleID' field.", statusCode: 400)
    }

    let matches = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == appReq.bundleID
    }

    guard !matches.isEmpty else {
        return errorResponse(message: "No running application with bundle ID '\(appReq.bundleID)'.", statusCode: 404)
    }

    for app in matches {
        app.terminate()
    }

    struct QuitResult: Encodable { let terminated: Bool; let bundleID: String }
    return jsonResponse(QuitResult(terminated: true, bundleID: appReq.bundleID))
}

/// Handles `GET /api/v1/apps/frontmost`.
///
/// Returns information about the currently active (frontmost) application.
private func handleFrontmostApp() -> Data {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let name = app.localizedName,
          let bundleID = app.bundleIdentifier else {
        return errorResponse(message: "No frontmost application.", statusCode: 404)
    }

    let info = AppInfo(
        name: name,
        bundleID: bundleID,
        isActive: true,
        pid: app.processIdentifier
    )
    return jsonResponse(info)
}

// MARK: - File System

/// Handles `GET /api/v1/fs?path=/some/dir`.
///
/// Lists the contents of the directory specified in the `path` query
/// parameter. Returns file names, types, and sizes.
///
/// - Parameter request: Must include a `path` query parameter.
private func handleListFS(_ request: AgentHTTPRequest) -> Data {
    guard let dirPath = request.query["path"], !dirPath.isEmpty else {
        return errorResponse(message: "Query parameter 'path' is required.", statusCode: 400)
    }

    let url = URL(fileURLWithPath: dirPath)
    let fm = FileManager.default

    do {
        let contents = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )

        let entries: [FSEntry] = contents.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return FSEntry(
                name: item.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: UInt64(values?.fileSize ?? 0)
            )
        }

        return jsonResponse(entries)
    } catch {
        return errorResponse(message: "Cannot list directory: \(error.localizedDescription)", statusCode: 400)
    }
}

// MARK: - File Transfer

/// The inbox directory where uploaded files are saved.
private let inboxDirectory: URL = {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Downloads")
        .appendingPathComponent("SpooktacularInbox")
}()

/// Handles `POST /api/v1/files`.
///
/// Saves a Base64-encoded file to `~/Downloads/SpooktacularInbox/`.
/// Creates the inbox directory if it does not exist.
///
/// - Parameter request: Must contain a JSON body with `name` and `data` fields.
private func handleUploadFile(_ request: AgentHTTPRequest) -> Data {
    guard let body = request.body,
          let payload = try? jsonDecoder.decode(FilePayload.self, from: body) else {
        return errorResponse(message: "Request body must contain 'name' and 'data' fields.", statusCode: 400)
    }

    guard let fileData = Data(base64Encoded: payload.data) else {
        return errorResponse(message: "Invalid Base64 in 'data' field.", statusCode: 400)
    }

    // Prevent directory traversal
    let safeName = URL(fileURLWithPath: payload.name).lastPathComponent
    guard !safeName.isEmpty, safeName != ".", safeName != ".." else {
        return errorResponse(message: "Invalid file name.", statusCode: 400)
    }

    let fm = FileManager.default
    do {
        try fm.createDirectory(at: inboxDirectory, withIntermediateDirectories: true)
    } catch {
        return errorResponse(message: "Failed to create inbox directory: \(error.localizedDescription)", statusCode: 500)
    }

    let destination = inboxDirectory.appendingPathComponent(safeName)
    do {
        try fileData.write(to: destination)
    } catch {
        return errorResponse(message: "Failed to write file: \(error.localizedDescription)", statusCode: 500)
    }

    log.info("Saved file '\(safeName, privacy: .public)' (\(fileData.count) bytes)")

    struct UploadResult: Encodable { let saved: Bool; let name: String; let size: Int }
    return jsonResponse(UploadResult(saved: true, name: safeName, size: fileData.count), statusCode: 201)
}

/// Handles `GET /api/v1/files`.
///
/// Lists files in `~/Downloads/SpooktacularInbox/`.
private func handleListFiles() -> Data {
    let fm = FileManager.default

    guard fm.fileExists(atPath: inboxDirectory.path) else {
        let empty: [FSEntry] = []
        return jsonResponse(empty)
    }

    do {
        let contents = try fm.contentsOfDirectory(
            at: inboxDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
        )

        let entries: [FSEntry] = contents.compactMap { item in
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            return FSEntry(
                name: item.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: UInt64(values?.fileSize ?? 0)
            )
        }

        return jsonResponse(entries)
    } catch {
        return errorResponse(message: "Cannot list inbox: \(error.localizedDescription)", statusCode: 500)
    }
}

// MARK: - Ports

/// Handles `GET /api/v1/ports`.
///
/// Uses `lsof -iTCP -sTCP:LISTEN -nP` to discover listening TCP
/// ports and the processes that own them.
private func handleListPorts() -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-iTCP", "-sTCP:LISTEN", "-nP", "-F", "pcn"]

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return errorResponse(message: "Failed to run lsof: \(error.localizedDescription)", statusCode: 500)
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""

    var ports: [PortInfo] = []
    var currentPID: Int32 = 0
    var currentName = ""

    for line in output.components(separatedBy: "\n") {
        guard !line.isEmpty else { continue }
        let prefix = line.first!
        let value = String(line.dropFirst())

        switch prefix {
        case "p":
            currentPID = Int32(value) ?? 0
        case "c":
            currentName = value
        case "n":
            // Format: "*:8080" or "127.0.0.1:3000" or "[::1]:443"
            if let colonIndex = value.lastIndex(of: ":") {
                let portString = String(value[value.index(after: colonIndex)...])
                if let port = UInt16(portString) {
                    ports.append(PortInfo(port: port, pid: currentPID, processName: currentName))
                }
            }
        default:
            break
        }
    }

    return jsonResponse(ports)
}
