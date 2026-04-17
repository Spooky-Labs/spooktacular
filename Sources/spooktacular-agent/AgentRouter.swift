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
/// | `POST` | `/api/v1/exec` | ``handleExec(_:)`` (break-glass only) |
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
import SpookCore

/// Constant-time string equality.
///
/// Bearer-token comparison in the guest agent must not short-circuit
/// on the first differing byte; otherwise an attacker who can measure
/// vsock round-trip latency can brute-force the token a character at
/// a time. Length is checked first (length is not secret); body
/// comparison is done with XOR-accumulator so the timing depends
/// only on length.
private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count {
        diff |= a[i] ^ b[i]
    }
    return diff == 0
}

/// Optional file-based audit sink for SIEM export.
/// Set SPOOK_AGENT_AUDIT_FILE to enable.
nonisolated(unsafe) private var agentAuditFile: FileHandle? = {
    guard let path = ProcessInfo.processInfo.environment["SPOOK_AGENT_AUDIT_FILE"],
          !path.isEmpty else {
        return nil
    }
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        let dir = URL(filePath: path).deletingLastPathComponent().path
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: path, contents: nil)
    }
    guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
    handle.seekToEndOfFile()
    return handle
}()

/// Shared JSON encoder for agent audit JSONL lines.
private let agentAuditEncoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    return enc
}()

/// Logger for agent route handlers.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "router")

/// Logger dedicated to the audit trail, visible in Console.app at `.notice` level.
private let auditLog = Logger(subsystem: "com.spooktacular.agent", category: "audit")

/// Maximum bytes captured from stdout/stderr for exec commands.
private let maxExecOutputBytes = 1_048_576 // 1 MB

/// Maximum concurrent exec commands allowed.
private let maxConcurrentExecs = 3

/// Serializes access to ``activeExecCount`` across the agent's
/// concurrent dispatch queues. `nonisolated(unsafe) var` alone was
/// not safe: two simultaneous requests could read the same count,
/// both pass the guard, both increment, and the limit degraded to
/// `maxConcurrentExecs + N` rather than `maxConcurrentExecs`. An
/// `os_unfair_lock` protects the increment-and-check as a single
/// atomic operation with no kernel-context-switch cost.
nonisolated(unsafe) private var _activeExecLock = os_unfair_lock()
nonisolated(unsafe) private var _activeExecCount: Int = 0

/// Attempts to reserve one of the ``maxConcurrentExecs`` slots.
/// Returns `true` on success; `false` when the limit is reached.
/// Callers MUST call ``releaseExecSlot()`` on success.
private func acquireExecSlot() -> Bool {
    os_unfair_lock_lock(&_activeExecLock)
    defer { os_unfair_lock_unlock(&_activeExecLock) }
    guard _activeExecCount < maxConcurrentExecs else { return false }
    _activeExecCount += 1
    return true
}

/// Releases an exec slot previously acquired with
/// ``acquireExecSlot()``. Safe to call in a `defer` block.
private func releaseExecSlot() {
    os_unfair_lock_lock(&_activeExecLock)
    defer { os_unfair_lock_unlock(&_activeExecLock) }
    _activeExecCount = max(0, _activeExecCount - 1)
}

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
/// - ``breakGlass``: Shell execution only — requires explicit break-glass authorization.
///
/// Conforms to `Comparable` so vsock channel scopes can be compared
/// against endpoint scopes: if the endpoint's scope exceeds the
/// channel's scope, the request is rejected at the transport layer.
enum EndpointScope: Int, Comparable {
    /// Read-only endpoints that inspect state without mutating it.
    case readonly = 0
    /// Runner-level mutation endpoints (apps, clipboard, files) — excludes exec.
    case runner = 1
    /// Break-glass endpoints — raw shell execution only.
    case breakGlass = 2

    static func < (lhs: EndpointScope, rhs: EndpointScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Human-readable label for log messages.
    var debugLabel: String {
        switch self {
        case .readonly: "readonly"
        case .runner: "runner"
        case .breakGlass: "break-glass"
        }
    }
}

/// Returns the ``EndpointScope`` for the given method/path pair,
/// or `nil` if the route is unknown.
private func endpointScope(method: String, path: String) -> EndpointScope? {
    switch (method, path) {
    // Break-glass — raw shell execution
    case ("POST", "/api/v1/exec"):
        return .breakGlass
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

/// Returns the default vsock port for a given endpoint scope.
///
/// Used in 403 error messages to guide callers to the correct channel.
///
/// | Scope | Port |
/// |-------|------|
/// | `.readonly` | 9470 |
/// | `.runner` | 9471 |
/// | `.breakGlass` | 9472 |
private func portForScope(_ scope: EndpointScope) -> UInt32 {
    switch scope {
    case .readonly: 9470
    case .runner: 9471
    case .breakGlass: 9472
    }
}

// MARK: - Router

/// The authorization tier determined from the presented Bearer token.
///
/// Used to enforce scope-based access control and to annotate audit log entries.
private enum AuthTier: String {
    /// Break-glass — all endpoints including exec.
    case breakGlass = "break-glass"
    /// Runner — mutation endpoints except exec.
    case runner
    /// Read-only — GET endpoints only.
    case readonly
}

/// Routes an ``AgentHTTPRequest`` to the appropriate handler.
///
/// When any token is configured the router enforces Bearer-token
/// authentication with three-tier scope-based authorization:
///
/// - **Break-glass token**: Grants access to all endpoints including exec.
/// - **Runner token**: Grants access to read-only and mutation endpoints,
///   but NOT exec. Exec returns 403 Forbidden.
/// - **Read-only token**: Grants access to read-only endpoints only.
///   Mutation and exec endpoints return 403 Forbidden.
///
/// If no token is configured the agent runs in legacy mode
/// (no auth, warning already logged at startup).
///
/// Before token authentication, the router enforces a **channel scope**
/// check. Each vsock port has a maximum scope; if the endpoint's scope
/// exceeds the channel's scope, the request is rejected with 403
/// regardless of the token presented. This provides physical isolation
/// between capability tiers at the transport layer.
///
/// After dispatching every request the router emits an audit-level log
/// entry via `os.Logger` at `.notice` so it appears in Console.app.
/// The log includes the resolved authorization tier.
///
/// - Parameters:
///   - request: The parsed HTTP request.
///   - channelScope: The maximum ``EndpointScope`` allowed on this vsock
///     channel. Defaults to `.breakGlass` for backward compatibility.
///   - adminToken: The break-glass Bearer token, — required.
///     Internally referred to as `breakGlassToken` to convey intent.
///   - runnerToken: The runner Bearer token, or `nil` if not configured.
///   - readonlyToken: The read-only Bearer token, or `nil` if not configured.
/// - Returns: A complete HTTP/1.1 response as raw bytes.
func routeRequest(
    _ request: AgentHTTPRequest,
    channelScope: EndpointScope = .breakGlass,
    adminToken breakGlassToken: String? = nil,
    runnerToken: String? = nil,
    readonlyToken: String? = nil,
    ticketVerifier: BreakGlassTicketVerifier? = nil
) -> Data {

    // --- Channel scope gate (transport-layer isolation) ---
    let requiredScope = endpointScope(method: request.method, path: request.path)
    if let required = requiredScope, required > channelScope {
        let response = errorResponse(
            message: "This channel does not support \(request.method) \(request.path). Use port \(portForScope(required)).",
            statusCode: 403
        )
        emitAuditLog(method: request.method, path: request.path, statusCode: 403, tier: nil)
        return response
    }

    // --- Auth gate ---
    //
    // Two credential paths converge on the same `authTier`:
    //   1. `bgt:`-prefixed break-glass ticket (OWASP-aligned,
    //      time-limited, single-use, Ed25519-signed)
    //   2. static Bearer token from the Keychain (runner /
    //      readonly / long-lived break-glass)
    //
    // Ticket failure does NOT fall through to the static path —
    // letting a malformed/expired/consumed ticket "try again as
    // a static token" would give an attacker two shots under
    // different credential types.
    let hasAnyToken = breakGlassToken != nil || runnerToken != nil || readonlyToken != nil
    var authTier: AuthTier?

    let rawAuth = request.headers["authorization"] ?? ""
    let rawBearer = rawAuth.hasPrefix("Bearer ")
        ? String(rawAuth.dropFirst("Bearer ".count))
        : ""

    if rawBearer.hasPrefix(BreakGlassTicket.wirePrefix) {
        guard let verifier = ticketVerifier else {
            let response = errorResponse(message: "Unauthorized.", statusCode: 401)
            emitAuditLog(method: request.method, path: request.path, statusCode: 401, tier: nil)
            return response
        }
        switch verifier.verify(ticket: rawBearer) {
        case .success(let ticket):
            log.notice(
                "Break-glass ticket consumed: jti=\(ticket.jti, privacy: .public) issuer=\(ticket.issuer, privacy: .public) reason=\(ticket.reason ?? "(none)", privacy: .public)"
            )
            authTier = .breakGlass
        case .failure(let err):
            log.warning("Break-glass ticket rejected: \(err.localizedDescription, privacy: .public)")
            let response = errorResponse(message: "Unauthorized.", statusCode: 401)
            emitAuditLog(method: request.method, path: request.path, statusCode: 401, tier: nil)
            return response
        }
    } else if hasAnyToken {
        let authHeader = request.headers["authorization"] ?? ""

        // Determine which token was presented.
        //
        // `==` on Swift `String` is short-circuiting and leaks the
        // byte-position of the first mismatch through timing —
        // classic oracle for recovering the break-glass token a
        // character at a time. `constantTimeEqual` below XOR-folds
        // every byte regardless of match state, so the comparison
        // time depends only on the length.
        let isBreakGlass = breakGlassToken.map {
            constantTimeEqual(authHeader, "Bearer \($0)")
        } ?? false
        let isRunner = runnerToken.map {
            constantTimeEqual(authHeader, "Bearer \($0)")
        } ?? false
        let isReadOnly = readonlyToken.map {
            constantTimeEqual(authHeader, "Bearer \($0)")
        } ?? false

        if isBreakGlass {
            authTier = .breakGlass
        } else if isRunner {
            authTier = .runner
        } else if isReadOnly {
            authTier = .readonly
        } else {
            let response = errorResponse(message: "Unauthorized.", statusCode: 401)
            emitAuditLog(method: request.method, path: request.path, statusCode: 401, tier: nil)
            return response
        }
    } else {
        // No static tokens configured AND no ticket presented —
        // the agent should have refused to start without any
        // credential source. Reject as a safety net.
        let response = errorResponse(message: "No authentication configured. Agent misconfigured.", statusCode: 500)
        emitAuditLog(method: request.method, path: request.path, statusCode: 500, tier: nil)
        return response
    }

    // By the time we reach here `authTier` is set — either via
    // the ticket path or the static-token path. The alternative
    // (Unauthorized / misconfigured) returned above.
    guard let resolvedTier = authTier else {
        // Defensive fallback — we should never hit this.
        let response = errorResponse(message: "Unauthorized.", statusCode: 401)
        emitAuditLog(method: request.method, path: request.path, statusCode: 401, tier: nil)
        return response
    }

    // Enforce scope restrictions
    let scope = endpointScope(method: request.method, path: request.path)
    switch resolvedTier {
    case .readonly:
        if scope == .runner || scope == .breakGlass {
            let message = scope == .breakGlass
                ? "Forbidden. Shell execution requires a break-glass token. See SECURITY.md for details."
                : "Forbidden. Read-only token cannot access mutation endpoints."
            let response = errorResponse(message: message, statusCode: 403)
            emitAuditLog(method: request.method, path: request.path, statusCode: 403, tier: resolvedTier)
            return response
        }
    case .runner:
        if scope == .breakGlass {
            let response = errorResponse(
                message: "Forbidden. Shell execution requires a break-glass token. See SECURITY.md for details.",
                statusCode: 403
            )
            emitAuditLog(method: request.method, path: request.path, statusCode: 403, tier: resolvedTier)
            return response
        }
    case .breakGlass:
        break // Break-glass allows everything
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
        // Defense-in-depth: re-assert the break-glass tier at the
        // handler boundary. The router already performs a tier
        // check above (lines ~314-335), but a future edit to the
        // scope table or a mis-routed fall-through could let a
        // runner/readonly caller reach this case. `handleExec`
        // itself now refuses anything below `.breakGlass` so the
        // single remaining enforcement point is co-located with
        // the dangerous operation — a custom client that bypasses
        // the port-tier gate still can't escalate to shell access
        // without a matching break-glass token.
        response = handleExec(request, authTier: resolvedTier)
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

    emitAuditLog(method: request.method, path: request.path, statusCode: statusCode, tier: resolvedTier)
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
    let timestamp = Date().ISO8601Format()
    let tierLabel = tier?.rawValue ?? "none"
    auditLog.notice("AUDIT: \(method, privacy: .public) \(path, privacy: .public) → \(statusCode) [\(tierLabel, privacy: .public)] [\(timestamp, privacy: .public)]")

    // For break-glass operations, also write a structured JSON line to the
    // agent audit file when SPOOK_AGENT_AUDIT_FILE is configured.
    if path == "/api/v1/exec", let handle = agentAuditFile {
        struct AgentAuditEntry: Encodable {
            let id: String
            let timestamp: String
            let actorIdentity: String
            let scope: String
            let resource: String
            let action: String
            let outcome: String
            let tier: String
        }
        let entry = AgentAuditEntry(
            id: UUID().uuidString,
            timestamp: timestamp,
            actorIdentity: "guest-agent",
            scope: "break-glass",
            resource: path,
            action: method,
            outcome: statusCode < 400 ? "success" : "failed",
            tier: tierLabel
        )
        if var data = try? agentAuditEncoder.encode(entry) {
            data.append(0x0A) // newline
            handle.write(data)
        }
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
    case 401: statusText = "Unauthorized"
    case 403: statusText = "Forbidden"
    case 404: statusText = "Not Found"
    case 429: statusText = "Too Many Requests"
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

/// **Break-glass only.** Raw shell execution is not available to
/// read-only or runner tokens. Requires explicit break-glass
/// authorization. Every invocation is audit-logged.
///
/// Handles `POST /api/v1/exec`.
///
/// Runs a shell command via `/bin/bash -c` and captures stdout,
/// stderr, and the exit code. An optional timeout (in seconds)
/// terminates the process if it exceeds the limit.
///
/// - Parameters:
///   - request: Must contain a JSON body with a `command` field.
///   - authTier: The resolved ``AuthTier`` for this request, as
///     determined by the router's token check. The handler refuses
///     any call that did not authenticate at ``AuthTier/breakGlass``
///     even if it somehow reached this dispatch — a defense-in-depth
///     check that co-locates the enforcement with the dangerous
///     operation so a routing regression can't silently expose
///     shell exec.
private func handleExec(_ request: AgentHTTPRequest, authTier: AuthTier) -> Data {
    // Defense-in-depth tier assertion. The router already checks
    // this upstream, but a custom client that crafts a
    // handler-level bypass (e.g. via a future code path that
    // dispatches without the scope gate) must not reach /bin/bash
    // without a break-glass token in hand.
    guard authTier == .breakGlass else {
        log.error("Rejected /api/v1/exec at handler tier gate: presented tier \(authTier.rawValue, privacy: .public)")
        return errorResponse(
            message: "Shell execution requires a break-glass token.",
            statusCode: 403
        )
    }

    guard let body = request.body,
          let execReq = try? jsonDecoder.decode(ExecRequest.self, from: body) else {
        return errorResponse(message: "Request body must contain 'command' field.", statusCode: 400)
    }

    // Enforce concurrent exec limit with an atomic slot reservation.
    // The previous read-then-increment pattern was racy under
    // concurrent dispatch and allowed limit overrun.
    guard acquireExecSlot() else {
        return errorResponse(
            message: "Too many concurrent exec commands. Maximum: \(maxConcurrentExecs).",
            statusCode: 429
        )
    }
    defer { releaseExecSlot() }

    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = ["-c", execReq.command]

    // Scrub SPOOK_AGENT_* from the child's environment. The agent
    // reads its auth tokens out of these variables at startup, so
    // leaking them into an exec'd shell hands a break-glass caller
    // the agent's own credentials — equivalent to giving them the
    // keys to impersonate every tier of the guest API. We also drop
    // SPOOK_AUDIT_SIGNING_KEY for the same reason.
    let parentEnv = ProcessInfo.processInfo.environment
    var childEnv: [String: String] = [:]
    for (key, value) in parentEnv where !key.hasPrefix("SPOOK_AGENT_") && !key.hasPrefix("SPOOK_AUDIT_") {
        childEnv[key] = value
    }
    process.environment = childEnv

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
        // Graceful SIGTERM first; a well-behaved child exits within
        // a few seconds and we can read whatever it already wrote.
        process.terminate()

        // Escalate to SIGKILL after a 5-second grace window. Without
        // this, a child that installs a SIGTERM handler (or ignores
        // the signal entirely) pins the exec slot forever — the
        // previous `waitUntilExit()` was an unbounded block that
        // let one rogue command DoS every subsequent exec call.
        let killDeadline = DispatchTime.now() + .seconds(5)
        if group.wait(timeout: killDeadline) == .timedOut {
            log.error("Exec child ignored SIGTERM, escalating to SIGKILL (pid \(process.processIdentifier))")
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        return errorResponse(message: "Command timed out after \(timeout) seconds.", statusCode: 500)
    }

    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    let stdout = String(data: stdoutData.prefix(maxExecOutputBytes), encoding: .utf8) ?? ""
    let stderr = String(data: stderrData.prefix(maxExecOutputBytes), encoding: .utf8) ?? ""

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

    // NSWorkspace's callback `openApplication` is the cleanest
    // fit for this synchronous vsock handler — the async overload
    // would force the whole router async, cascading through every
    // caller. The lock + `os_unfair_lock`-protected error slot is
    // Swift 6-safe: `LaunchSlot` owns its state, the callback and
    // the waiter never touch `launchError` concurrently, and we
    // avoid the `nonisolated(unsafe)` footgun entirely.
    final class LaunchSlot: @unchecked Sendable {
        private let lock = NSLock()
        private var err: (any Error)?
        func set(_ error: (any Error)?) { lock.withLock { err = error } }
        var value: (any Error)? { lock.withLock { err } }
    }

    let config = NSWorkspace.OpenConfiguration()
    let semaphore = DispatchSemaphore(value: 0)
    let slot = LaunchSlot()
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
        slot.set(error)
        semaphore.signal()
    }
    semaphore.wait()

    if let error = slot.value {
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
/// Allowed roots for `GET /api/v1/fs`.
///
/// Previously the endpoint accepted any absolute path and returned
/// its contents — effectively a full filesystem read for anyone
/// holding a runner or break-glass token. The fix is a positive
/// allow-list rooted at the current user's home directory, with
/// path resolution that follows symlinks before comparison (so a
/// symlink inside the home can't escape).
private let fsAllowedRoots: [URL] = [
    FileManager.default.homeDirectoryForCurrentUser,
    URL(filePath: "/tmp"),
    URL(filePath: "/var/tmp"),
]

/// Handles `GET /api/v1/fs?path=/some/dir`.
///
/// Lists the contents of the directory specified in the `path` query
/// parameter, **contained within the allowed roots**. Attempts to
/// traverse outside — `../../etc`, `/var/root/.ssh`, a symlink to
/// `/private` — return 403.
///
/// - Parameter request: Must include a `path` query parameter.
private func handleListFS(_ request: AgentHTTPRequest) -> Data {
    guard let dirPath = request.query["path"], !dirPath.isEmpty else {
        return errorResponse(message: "Query parameter 'path' is required.", statusCode: 400)
    }

    // Resolve to a fully-resolved, symlinks-followed absolute path
    // before the containment check. `standardizedFileURL` collapses
    // `..` components; `resolvingSymlinksInPath` chases aliases.
    let resolved = URL(filePath: dirPath)
        .standardizedFileURL
        .resolvingSymlinksInPath()

    // Path-component containment — NOT raw hasPrefix. A plain prefix
    // test lets sibling directories that share a character prefix
    // escape the allow-list: if the agent runs as `admin` (home
    // `/Users/admin`), `/Users/administrator/...` and `/Users/admin2`
    // both satisfy `hasPrefix("/Users/admin")`. Appending a separator
    // before the comparison forces the match to end at a directory
    // boundary, and we also accept exact equality with the root
    // itself. Resolve symlinks on both sides so the allow-list entry
    // `/tmp` canonicalizes to `/private/tmp` on macOS the same way
    // any user-supplied `/tmp/...` path does — otherwise legitimate
    // `/tmp` access would fail the check.
    guard fsAllowedRoots.contains(where: { root in
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        if resolved.path == rootPath { return true }
        let rootWithSep = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return resolved.path.hasPrefix(rootWithSep)
    }) else {
        return errorResponse(
            message: "Access denied: path is outside the allowed roots.",
            statusCode: 403
        )
    }

    let fm = FileManager.default
    do {
        let contents = try fm.contentsOfDirectory(
            at: resolved,
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
    let safeName = URL(filePath: payload.name).lastPathComponent
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
    process.executableURL = URL(filePath: "/usr/sbin/lsof")
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
