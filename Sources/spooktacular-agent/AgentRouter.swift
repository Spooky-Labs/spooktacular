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
/// | `POST` | `/api/v1/exec` | ``handleExec(_:)`` |
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

// MARK: - Router

/// Routes an ``AgentHTTPRequest`` to the appropriate handler.
///
/// Returns a raw HTTP response as `Data`, ready to write to the socket.
/// Unmatched routes receive a 404 response.
///
/// - Parameter request: The parsed HTTP request.
/// - Returns: A complete HTTP/1.1 response as raw bytes.
func routeRequest(_ request: AgentHTTPRequest) -> Data {
    switch (request.method, request.path) {
    case ("GET", "/health"):
        return handleHealth()
    case ("GET", "/api/v1/clipboard"):
        return handleGetClipboard()
    case ("POST", "/api/v1/clipboard"):
        return handleSetClipboard(request)
    case ("POST", "/api/v1/exec"):
        return handleExec(request)
    case ("GET", "/api/v1/apps"):
        return handleListApps()
    case ("POST", "/api/v1/apps/launch"):
        return handleLaunchApp(request)
    case ("POST", "/api/v1/apps/quit"):
        return handleQuitApp(request)
    case ("GET", "/api/v1/apps/frontmost"):
        return handleFrontmostApp()
    case ("GET", "/api/v1/fs"):
        return handleListFS(request)
    case ("POST", "/api/v1/files"):
        return handleUploadFile(request)
    case ("GET", "/api/v1/files"):
        return handleListFiles()
    case ("GET", "/api/v1/ports"):
        return handleListPorts()
    default:
        return errorResponse(message: "Not found.", statusCode: 404)
    }
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
