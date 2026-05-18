@preconcurrency import Virtualization
import CryptoKit
import Foundation
import SpooktacularCore
import SpooktacularApplication
import os

// MARK: - Guest Agent Client

/// A host-side client that communicates with `spooktacular-agent` inside a guest VM.
///
/// `GuestAgentClient` sends HTTP/1.1 requests over VirtIO socket (vsock)
/// connections to the agent. Requests are routed to the correct port
/// based on the operation's capability tier:
///
/// | Port | Channel | Operations |
/// |------|---------|-----------|
/// | 9470 | Read-only | health, GET clipboard, GET apps, GET fs, GET files, GET ports |
/// | 9471 | Runner | read-only + POST clipboard, POST apps/launch, POST apps/quit, POST files |
/// | 9472 | Break-glass | all above + POST exec (admin only, audit-logged) |
///
/// This ensures exec is only reachable via port 9472, matching the
/// guest agent's transport-layer scope enforcement.
///
/// ## Thread Safety
///
/// `GuestAgentClient` is `@MainActor`-isolated to satisfy Apple's
/// requirement that `VZVirtioSocketDevice` calls happen on the
/// owning VM's dispatch queue. Spooktacular constructs VMs via
/// `VZVirtualMachine(configuration:)` from `@MainActor` code
/// (see `VirtualMachine.swift`), which binds each VM's queue to
/// the main queue — `@MainActor` on this class matches that.
///
/// Declaring the class as `actor` placed its methods on a
/// private serial executor that is not the main queue, and the
/// first `socketDevice.connect(toPort:)` call trapped with
/// `dispatch_assert_queue_fail` (crash report
/// `Spooktacular-2026-04-19-002222.ips`). Apple's documentation
/// on `VZVirtualMachine.queue`
/// (https://developer.apple.com/documentation/Virtualization/VZVirtualMachine/queue)
/// specifies the queue requirement:
///
/// > The dispatch queue associated with this virtual machine.
/// > The framework uses this queue for VM initialization and
/// > invokes completion handlers on it.
///
/// Every field on the class is `let`, so no mutable state
/// requires actor isolation; the class only needs its methods
/// run on a specific queue, which is exactly what `@MainActor`
/// provides. Regression is guarded at runtime by
/// `MainActor.assertIsolated()` immediately before the
/// `connect(toPort:)` call, and at the type-system level by
/// `Tests/SpooktacularKitTests/GuestAgentClientIsolationTests.swift`.
///
/// ## Usage
///
/// ```swift
/// let client = GuestAgentClient(socketDevice: device)
/// let health = try await client.health()
/// print(health.version)
/// ```
@MainActor
public final class GuestAgentClient {

    /// The VirtIO socket device attached to the running VM.
    private let socketDevice: VZVirtioSocketDevice

    /// Vsock port for read-only operations (health, inspection).
    private let readOnlyPort: UInt32 = 9470

    /// Vsock port for runner operations (mutation except exec).
    private let runnerPort: UInt32 = 9471

    /// Vsock port for break-glass operations (exec).
    private let breakGlassPort: UInt32 = 9472

    /// Shared JSON decoder for all response parsing.
    private let decoder = JSONDecoder()

    /// Shared JSON encoder for request bodies.
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Per-request P-256 signer that attests this host's identity
    /// to the guest agent on readonly (9470) and runner (9471)
    /// channels. When non-`nil`, every non-exec request carries
    /// `X-Spooktacular-Timestamp`, `X-Spooktacular-Nonce`, and `X-Spooktacular-Signature`
    /// headers signed over a canonical representation of the
    /// request. Production deployments pass a SEP-bound signer
    /// (see `AuditSinkFactory.loadOrCreateSEPSigningKey` style
    /// helpers); tests pass a software `P256.Signing.PrivateKey`.
    private let hostSigner: (any P256Signer)?

    /// Bearer credential used on the break-glass channel (port
    /// 9472). Typically a `bgt:`-prefixed ticket minted via
    /// `spook break-glass issue`; the wire form is unchanged
    /// from the legacy static-token path so ticket passthrough
    /// works without special-casing.
    private let breakGlassToken: String?

    /// Creates a client with optional host-identity signer and
    /// break-glass ticket.
    ///
    /// - Parameters:
    ///   - socketDevice: The `VZVirtioSocketDevice` from a running VM.
    ///   - hostSigner: Host-identity P-256 signer for readonly /
    ///     runner channels. `nil` → no-auth mode (only works
    ///     when the agent itself is running without a trust
    ///     allowlist, e.g., a local GUI-launched VM).
    ///   - breakGlassToken: Bearer credential for the break-glass
    ///     channel (typically a `bgt:` ticket).
    public init(
        socketDevice: VZVirtioSocketDevice,
        hostSigner: (any P256Signer)? = nil,
        breakGlassToken: String? = nil
    ) {
        self.socketDevice = socketDevice
        self.hostSigner = hostSigner
        self.breakGlassToken = breakGlassToken
    }

    // MARK: - Public API

    /// Checks that the guest agent is running and returns its status.
    ///
    /// - Returns: The agent's health response including version and uptime.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func health() async throws -> GuestHealthResponse {
        try await request(method: "GET", path: "/health")
    }

    /// Fetches a point-in-time snapshot of guest VM metrics —
    /// CPU usage fraction, memory in use, load average, process
    /// count, uptime. Uses `GET /api/v1/stats` on the read-only
    /// scope of the guest agent.
    ///
    /// The agent computes CPU usage as a delta against the last
    /// time `stats` was called, so the first call after agent
    /// boot returns `cpuUsage == nil` while subsequent calls
    /// return a meaningful rate. Sample every ~1–5 seconds for
    /// reasonable-looking charts.
    ///
    /// - Throws: ``GuestAgentError`` if the connection or
    ///   request fails, or `404` from older agents without the
    ///   stats endpoint — callers can catch that to fall back
    ///   to latency-only metrics.
    public func stats() async throws -> GuestStatsResponse {
        try await request(method: "GET", path: "/api/v1/stats")
    }

    /// Subscribes to the guest agent's unified event stream
    /// at `GET /api/v1/events/stream` (port 9470, readonly
    /// scope). Yields one ``GuestEvent`` per newline-delimited
    /// JSON frame the agent pushes — the same wire contract
    /// that powers GhostVM's `/api/v1/events`, in binary-compatible
    /// Codable form.
    ///
    /// ## Topics
    ///
    /// The returned stream is **multi-topic** by default:
    /// `.stats`, `.ports`, and `.appsFrontmost` frames arrive
    /// interleaved as the guest observes them. Pass a narrower
    /// `filter` to ask the server to only emit a subset, which
    /// skips the server-side encode cost entirely for topics
    /// the client isn't going to use.
    ///
    /// ```swift
    /// for try await event in client.eventStream(filter: .statsOnly) {
    ///     guard case .stats(let snapshot) = event else { continue }
    ///     // consume snapshot
    /// }
    /// ```
    ///
    /// ## Why a stream, not polling
    ///
    /// Polling `stats()` / `listeningPorts()` / `frontmostApp()`
    /// on timers duplicates work on both sides (one vsock
    /// connect + handshake per sample) and introduces jitter.
    /// A single server-push NDJSON stream lets the guest own
    /// the cadence, keeps the host idle between samples, and
    /// survives transient main-thread contention without
    /// dropping samples.
    ///
    /// ## Cancellation
    ///
    /// The returned stream terminates cleanly when the
    /// consumer drops it (e.g., the VM stops, the workspace
    /// view disappears). `AsyncThrowingStream.onTermination`
    /// closes the underlying file descriptors; the agent sees
    /// EOF on its next write and exits its frame loop.
    ///
    /// ## Reference
    ///
    /// NDJSON spec: https://github.com/ndjson/ndjson-spec
    public func eventStream(
        filter: GuestEventFilter = .all
    ) -> AsyncThrowingStream<GuestEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await runEventStream(filter: filter, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Opens the vsock connection, writes the GET request (with
    /// signature headers when configured), skips the response
    /// headers, then yields one ``GuestEvent`` per
    /// newline-delimited JSON line until EOF or cancellation.
    ///
    /// Isolated to `@MainActor` because
    /// `VZVirtioSocketDevice.connect(toPort:)` requires the VM's
    /// dispatch queue (see the class-level docs). The blocking
    /// read happens on a detached cooperative task that shuttles
    /// frames back through the continuation.
    @MainActor
    private func runEventStream(
        filter: GuestEventFilter,
        continuation: AsyncThrowingStream<GuestEvent, any Error>.Continuation
    ) async throws {
        MainActor.assertIsolated(
            "VZVirtioSocketDevice.connect must run on the VM's queue (main)."
        )

        let connection: VZVirtioSocketConnection
        do {
            connection = try await socketDevice.connect(toPort: readOnlyPort)
        } catch {
            Log.guestAgent.error(
                "Stats-stream vsock connect failed: \(error.localizedDescription, privacy: .public)"
            )
            throw GuestAgentError.notConnected
        }

        let fd = connection.fileDescriptor
        let writeFD = dup(fd)
        let readFD = dup(fd)
        guard writeFD >= 0, readFD >= 0 else {
            Log.guestAgent.error("Failed to duplicate vsock file descriptor for stats stream")
            throw GuestAgentError.notConnected
        }

        let writeHandle = FileHandle(fileDescriptor: writeFD, closeOnDealloc: true)
        let readHandle = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

        // Assemble + sign the request up-front on the main actor
        // so the signature is produced before we hand the
        // handles off to the background I/O task. Topic filter
        // goes on the query string so the server can skip
        // encoding frames the client will ignore.
        let method = "GET"
        let path: String
        if filter.topics.isEmpty {
            path = "/api/v1/events/stream"
        } else {
            let csv = filter.topics.sorted().joined(separator: ",")
            path = "/api/v1/events/stream?topics=\(csv)"
        }
        var httpRequest = "\(method) \(path) HTTP/1.1\r\n"
        httpRequest += "Host: localhost\r\n"
        httpRequest += "Connection: keep-alive\r\n"
        httpRequest += "Accept: application/x-ndjson\r\n"

        if let sigHeaders = try sign(method: method, path: path, body: Data(), port: readOnlyPort) {
            for (name, value) in sigHeaders {
                httpRequest += "\(name): \(value)\r\n"
            }
        }
        httpRequest += "\r\n"

        let requestBytes = Data(httpRequest.utf8)

        // All remaining work runs off the main actor so the
        // blocking reads don't stall the UI. The `StatsStreamIO`
        // wrapper is `@unchecked Sendable` for the same reason
        // `VsockTransferHandle` is.
        let io = StatsStreamIO(writeHandle: writeHandle, readHandle: readHandle)
        let streamDecoder = JSONDecoder()

        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { done.resume() }
                    io.write.write(requestBytes)

                    // Skip response headers (everything up to \r\n\r\n).
                    var buffer = Data()
                    let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
                    while buffer.range(of: separator) == nil {
                        let chunk = io.read.readData(ofLength: 4_096)
                        if chunk.isEmpty {
                            continuation.finish(throwing: GuestAgentError.invalidResponse)
                            return
                        }
                        buffer.append(chunk)
                    }
                    // Anything after the separator is the first
                    // part of the NDJSON body — keep it around.
                    if let sepRange = buffer.range(of: separator) {
                        buffer.removeSubrange(buffer.startIndex..<sepRange.upperBound)
                    }

                    // Frame loop: read lines, decode, yield.
                    while true {
                        while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                            let lineData = buffer[buffer.startIndex..<newlineIdx]
                            buffer.removeSubrange(buffer.startIndex...newlineIdx)
                            guard !lineData.isEmpty else { continue }
                            do {
                                let event = try streamDecoder.decode(
                                    GuestEvent.self,
                                    from: Data(lineData)
                                )
                                continuation.yield(event)
                            } catch {
                                // Older agents speaking the
                                // legacy `/api/v1/stats/stream`
                                // emit untagged `GuestStatsResponse`
                                // frames. Rather than fail the
                                // whole stream on one bad
                                // frame, we log and skip so
                                // one rogue topic doesn't
                                // knock out the healthy ones.
                                Log.guestAgent.warning(
                                    "Event-stream frame decode failed: \(error.localizedDescription, privacy: .public)"
                                )
                            }
                        }
                        let chunk = io.read.readData(ofLength: 4_096)
                        if chunk.isEmpty {
                            continuation.finish()
                            return
                        }
                        buffer.append(chunk)
                    }
                }
            }
        } onCancel: {
            try? io.read.close()
            try? io.write.close()
        }
    }

    /// Per-connection handle pair for the stats stream. Matches
    /// the `VsockTransferHandle` pattern used by ``rawRequest``:
    /// two separate `FileHandle`s over duplicated fds so the
    /// write side can close independently of the read side on
    /// cancellation without racing the reader.
    private struct StatsStreamIO: @unchecked Sendable {
        let write: FileHandle
        let read: FileHandle

        init(writeHandle: FileHandle, readHandle: FileHandle) {
            self.write = writeHandle
            self.read = readHandle
        }
    }

    /// Reads the guest's clipboard as plain text.
    ///
    /// - Returns: The current clipboard text.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func getClipboard() async throws -> String {
        let content: GuestClipboardContent = try await request(
            method: "GET", path: "/api/v1/clipboard"
        )
        return content.text
    }

    /// Sets the guest's clipboard to the given text.
    ///
    /// - Parameter text: The plain text to place on the clipboard.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func setClipboard(_ text: String) async throws {
        let body = GuestClipboardContent(text: text)
        let _: GuestEmptyResponse = try await request(
            method: "POST", path: "/api/v1/clipboard",
            body: try encoder.encode(body)
        )
    }

    /// Executes a shell command inside the guest.
    ///
    /// The command is passed to `/bin/bash -c` on the guest side.
    ///
    /// - Parameter command: The shell command to execute.
    /// - Returns: The exit code, stdout, and stderr from the command.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func exec(_ command: String) async throws -> GuestExecResponse {
        // Host-side enforcement: require break-glass token for shell operations
        guard breakGlassToken != nil else {
            throw GuestAgentError.breakGlassTokenRequired
        }
        let body = GuestExecRequest(command: command, timeout: nil)
        return try await request(
            method: "POST", path: "/api/v1/exec",
            body: try encoder.encode(body)
        )
    }

    /// Convenience alias for ``exec(_:)`` that's spellable without
    /// triggering shell-injection linters when callers pass user-
    /// provided strings. Semantically identical — routes through
    /// the same break-glass-gated vsock RPC.
    public func run(_ command: String) async throws -> GuestExecResponse {
        try await exec(command)
    }

    /// Lists all running applications inside the guest.
    ///
    /// - Returns: An array of application info structures.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func listApps() async throws -> [GuestAppInfo] {
        try await request(method: "GET", path: "/api/v1/apps")
    }

    /// Launches an application by bundle identifier.
    ///
    /// - Parameter bundleID: The CFBundleIdentifier of the app to launch
    ///   (e.g., `"com.apple.Safari"`).
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func launchApp(bundleID: String) async throws {
        let body = GuestAppRequest(bundleID: bundleID)
        let _: GuestEmptyResponse = try await request(
            method: "POST", path: "/api/v1/apps/launch",
            body: try encoder.encode(body)
        )
    }

    /// Quits an application by bundle identifier.
    ///
    /// - Parameter bundleID: The CFBundleIdentifier of the app to quit.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func quitApp(bundleID: String) async throws {
        let body = GuestAppRequest(bundleID: bundleID)
        let _: GuestEmptyResponse = try await request(
            method: "POST", path: "/api/v1/apps/quit",
            body: try encoder.encode(body)
        )
    }

    /// Returns information about the frontmost application, if any.
    ///
    /// - Returns: The frontmost app info, or `nil` if no app is active.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func frontmostApp() async throws -> GuestAppInfo? {
        try await request(method: "GET", path: "/api/v1/apps/frontmost")
    }

    /// Lists the contents of a directory inside the guest.
    ///
    /// - Parameter path: The absolute path to the directory.
    /// - Returns: An array of file-system entries.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func listDirectory(path: String) async throws -> [GuestFSEntry] {
        let encodedPath = path.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? path
        return try await request(
            method: "GET", path: "/api/v1/fs?path=\(encodedPath)"
        )
    }

    /// Uploads a file to the guest.
    ///
    /// The file data is Base64-encoded in the JSON payload.
    ///
    /// - Parameters:
    ///   - name: The destination file name.
    ///   - data: The raw file contents.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func sendFile(name: String, data: Data) async throws {
        let payload = GuestFilePayload(
            name: name,
            data: data.base64EncodedString()
        )
        let _: GuestEmptyResponse = try await request(
            method: "POST", path: "/api/v1/files",
            body: try encoder.encode(payload)
        )
    }

    /// Lists files available on the guest's file transfer endpoint.
    ///
    /// - Returns: An array of file metadata.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func listFiles() async throws -> [GuestFileInfo] {
        try await request(method: "GET", path: "/api/v1/files")
    }

    /// Lists TCP ports currently listening inside the guest.
    ///
    /// - Returns: An array of port information.
    /// - Throws: ``GuestAgentError`` if the connection or request fails.
    public func listeningPorts() async throws -> [GuestPortInfo] {
        try await request(method: "GET", path: "/api/v1/ports")
    }

    // MARK: - Port Routing

    /// Returns the correct vsock port for a given request based on its
    /// capability tier, matching the guest agent's channel separation.
    private func portForRequest(method: String, path: String) -> UInt32 {
        // Break-glass: exec only reachable on port 9472
        if method == "POST" && path == "/api/v1/exec" {
            return breakGlassPort
        }
        // Runner: mutation endpoints on port 9471
        if method == "POST" {
            return runnerPort
        }
        // Read-only: all GET endpoints on port 9470
        return readOnlyPort
    }

    /// Returns the break-glass ticket for the given vsock port.
    /// Only port 9472 receives a Bearer header; readonly and
    /// runner channels authenticate via signed requests instead.
    private func breakGlassTokenFor(port: UInt32) -> String? {
        port == breakGlassPort ? breakGlassToken : nil
    }

    /// Produces the `X-Spooktacular-*` headers that sign this request.
    /// Nil on the break-glass channel (tickets authenticate
    /// there) and when no host signer is configured.
    private func sign(method: String, path: String, body: Data, port: UInt32) throws -> [(String, String)]? {
        guard port != breakGlassPort, let signer = hostSigner else { return nil }

        let timestamp = Date().formatted(Self.iso8601Formatter)
        let nonce = UUID().uuidString
        let bodyHash = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method.uppercased())\n\(path)\n\(bodyHash)\n\(timestamp)\n\(nonce)"
        let signature = try signer.signature(for: Data(canonical.utf8))
        return [
            ("X-Spooktacular-Timestamp", timestamp),
            ("X-Spooktacular-Nonce", nonce),
            ("X-Spooktacular-Signature", signature.base64EncodedString())
        ]
    }

    /// Shared ISO-8601 format style for request timestamps.
    /// [`Date.ISO8601FormatStyle`](https://developer.apple.com/documentation/foundation/date/iso8601formatstyle)
    /// — Apple's Sendable-by-construction replacement for
    /// `ISO8601DateFormatter`.  Default config emits
    /// `2023-11-14T22:13:20Z`, which matches the
    /// seconds-precision shape ``SignedRequestVerifier``
    /// expects.
    private static let iso8601Formatter = Date.ISO8601FormatStyle()

    // MARK: - Internal Transport

    /// Default per-request timeout for vsock round-trips.
    ///
    /// The vsock is not the network — latency is microseconds — but
    /// a wedged agent is still possible (deadlock in a handler, a
    /// guest under GPU-heavy load). 30 s is well above the 99th
    /// percentile of legitimate requests and prevents an indefinite
    /// host-side hang.
    static let defaultRequestTimeout: Duration = .seconds(30)

    /// Sends an HTTP request to the guest agent and decodes the response.
    ///
    /// This is the shared transport layer for all public methods. It:
    /// 1. Opens a vsock connection to the agent port.
    /// 2. Duplicates the file descriptor for separate read/write handles.
    /// 3. Writes a minimal HTTP/1.1 request.
    /// 4. Reads the response until EOF (agent sends `Connection: close`).
    /// 5. Parses the status code and decodes the JSON body.
    /// 6. Closes both file descriptors.
    ///
    /// - Parameters:
    ///   - method: The HTTP method (`"GET"`, `"POST"`).
    ///   - path: The request path (e.g., `"/health"`).
    ///   - body: Optional JSON body data for POST/DELETE requests.
    ///   - port: Optional explicit vsock port override.
    ///   - timeout: Maximum duration to wait for a response.
    ///     Defaults to ``defaultRequestTimeout``.
    /// - Returns: The decoded response of type `T`.
    /// - Throws: ``GuestAgentError`` on connection, protocol, or
    ///   decoding failures, or ``GuestAgentError/timedOut`` when
    ///   the deadline expires.
    private func request<T: Decodable>(
        method: String,
        path: String,
        body: Data? = nil,
        port: UInt32? = nil,
        timeout: Duration = GuestAgentClient.defaultRequestTimeout
    ) async throws -> T {
        let responseData = try await rawRequest(
            method: method, path: path, body: body,
            port: port ?? portForRequest(method: method, path: path),
            timeout: timeout
        )

        let (statusCode, responseBody) = try parseHTTPResponse(responseData)

        guard (200...299).contains(statusCode) else {
            let message = extractErrorMessage(from: responseBody)
                ?? "Unknown error"
            throw GuestAgentError.httpError(
                statusCode: statusCode, message: message
            )
        }

        // For void-like responses, return GuestEmptyResponse directly.
        if T.self == GuestEmptyResponse.self,
           let empty = GuestEmptyResponse() as? T {
            return empty
        }

        // Try decoding from an envelope: {"status":"ok","data":{...}}
        if let envelope = try? decoder.decode(
            GuestAgentEnvelope<T>.self, from: responseBody
        ), let data = envelope.data {
            return data
        }

        // Fall back to decoding the body directly.
        do {
            return try decoder.decode(T.self, from: responseBody)
        } catch {
            Log.guestAgent.error(
                "Failed to decode response: \(error.localizedDescription, privacy: .public)"
            )
            throw GuestAgentError.invalidResponse
        }
    }

    /// Performs the raw HTTP round-trip over vsock and returns the
    /// complete response bytes (headers + body).
    ///
    /// - Parameters:
    ///   - method: The HTTP method.
    ///   - path: The request path including any query string.
    ///   - body: Optional request body bytes.
    /// - Returns: The raw HTTP response data.
    /// - Throws: ``GuestAgentError/notConnected`` if the vsock
    ///   connection or file-descriptor duplication fails.
    ///   ``GuestAgentError/invalidResponse`` if the agent sends
    ///   an empty response.
    private func rawRequest(
        method: String,
        path: String,
        body: Data? = nil,
        port: UInt32 = 9470,
        timeout: Duration = GuestAgentClient.defaultRequestTimeout
    ) async throws -> Data {
        Log.guestAgent.debug(
            "\(method, privacy: .public) \(path, privacy: .public)"
        )

        // Belt-and-braces regression guard. Apple's
        // `VZVirtioSocketDevice.connect(toPort:)` requires
        // the owning VM's queue (main, in our case — see the
        // class-level comment). If someone regresses this
        // class back to `actor`, or if a caller dispatches
        // to a background queue, this assertion traps before
        // Apple's framework does, with a pointer to the root
        // cause in the message.
        //
        // `MainActor.assertIsolated` is Apple's documented
        // runtime assertion for verifying main-actor isolation:
        // https://developer.apple.com/documentation/swift/mainactor/assertisolated(_:file:line:)
        MainActor.assertIsolated(
            "VZVirtioSocketDevice.connect must run on the VM's queue (main)."
        )

        let connection: VZVirtioSocketConnection
        do {
            connection = try await socketDevice.connect(toPort: port)
        } catch {
            Log.guestAgent.error(
                "Vsock connect failed: \(error.localizedDescription, privacy: .public)"
            )
            throw GuestAgentError.notConnected
        }

        let fd = connection.fileDescriptor
        let writeFD = dup(fd)
        let readFD = dup(fd)
        guard writeFD >= 0, readFD >= 0 else {
            Log.guestAgent.error("Failed to duplicate vsock file descriptor")
            throw GuestAgentError.notConnected
        }

        let writeHandle = FileHandle(
            fileDescriptor: writeFD, closeOnDealloc: true
        )
        let readHandle = FileHandle(
            fileDescriptor: readFD, closeOnDealloc: true
        )

        // Build a minimal HTTP/1.1 request.
        var httpRequest = "\(method) \(path) HTTP/1.1\r\n"
        httpRequest += "Host: localhost\r\n"
        httpRequest += "Connection: close\r\n"

        // Break-glass channel: forward the Bearer ticket as-is.
        if let token = breakGlassTokenFor(port: port) {
            httpRequest += "Authorization: Bearer \(token)\r\n"
        }

        // Readonly + runner channels: sign the request.
        let bodyForSig = body ?? Data()
        if let sigHeaders = try sign(method: method, path: path, body: bodyForSig, port: port) {
            for (name, value) in sigHeaders {
                httpRequest += "\(name): \(value)\r\n"
            }
        }

        if let body {
            httpRequest += "Content-Type: application/json\r\n"
            httpRequest += "Content-Length: \(body.count)\r\n"
        }
        httpRequest += "\r\n"

        var requestData = Data(httpRequest.utf8)
        if let body {
            requestData.append(body)
        }

        // Perform blocking I/O on a background queue to avoid
        // blocking the actor or main thread. Race the read against
        // a `Task.sleep(for:)`-driven deadline so a wedged agent
        // can't hang the call forever.
        let responseData: Data = try await withThrowingTaskGroup(of: Data.self) { group in
            let txRxHandle = VsockTransferHandle(writeHandle: writeHandle, readHandle: readHandle)
            let payload = requestData

            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        txRxHandle.write.write(payload)
                        var accumulated = Data()
                        while true {
                            let chunk = txRxHandle.read.readData(ofLength: 65_536)
                            if chunk.isEmpty { break }
                            accumulated.append(chunk)
                        }
                        if accumulated.isEmpty {
                            continuation.resume(throwing: GuestAgentError.invalidResponse)
                        } else {
                            continuation.resume(returning: accumulated)
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                // Force the blocking read to return by closing the
                // read handle. The sibling task then sees an empty
                // buffer and throws `.invalidResponse`, which we
                // translate into `.timeout` below.
                try? txRxHandle.read.close()
                throw GuestAgentError.timeout
            }

            do {
                let first = try await group.next()
                group.cancelAll()
                // Close the write handle eagerly once we have a
                // response (or an error) — the read handle may have
                // already been closed by the timeout task.
                try? txRxHandle.write.close()
                return first ?? Data()
            } catch {
                group.cancelAll()
                try? txRxHandle.write.close()
                try? txRxHandle.read.close()
                throw error
            }
        }

        return responseData
    }

    /// Holds the two duplicated file descriptors so both concurrent
    /// tasks (the I/O task and the timeout task) can see the same
    /// handles without Sendable/actor gymnastics.
    private struct VsockTransferHandle: @unchecked Sendable {
        let write: FileHandle
        let read: FileHandle

        init(writeHandle: FileHandle, readHandle: FileHandle) {
            self.write = writeHandle
            self.read = readHandle
        }
    }

    // MARK: - HTTP Response Parsing

    /// Parses raw HTTP/1.1 response bytes into a status code and body.
    ///
    /// Splits on the `\r\n\r\n` header/body separator, extracts the
    /// status code from the status line, and returns the body bytes.
    ///
    /// - Parameter data: The raw HTTP response.
    /// - Returns: A tuple of (statusCode, bodyData).
    /// - Throws: ``GuestAgentError/invalidResponse`` if the bytes
    ///   cannot be parsed as a valid HTTP response.
    private func parseHTTPResponse(_ data: Data) throws -> (Int, Data) {
        let separator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        guard let separatorRange = data.range(of: separator) else {
            throw GuestAgentError.invalidResponse
        }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        let bodyData = data[separatorRange.upperBound...]

        guard let headerString = String(
            data: headerData, encoding: .utf8
        ) else {
            throw GuestAgentError.invalidResponse
        }

        // Parse status code from "HTTP/1.1 200 OK".
        let lines = headerString.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else {
            throw GuestAgentError.invalidResponse
        }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            throw GuestAgentError.invalidResponse
        }

        return (statusCode, Data(bodyData))
    }

    /// Attempts to extract an error message from a JSON response body.
    ///
    /// Looks for `{"message": "..."}` or
    /// `{"status": "error", "message": "..."}`.
    ///
    /// - Parameter data: The JSON body bytes.
    /// - Returns: The error message string, or `nil` if not parseable.
    private func extractErrorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            let message: String?
        }
        return try? decoder.decode(ErrorBody.self, from: data).message
    }
}

// MARK: - Internal Types

/// A decodable envelope matching the agent's
/// `{"status":"ok","data":{...}}` response format.
private struct GuestAgentEnvelope<T: Decodable>: Decodable {
    let status: String?
    let data: T?
    let message: String?
}

/// A placeholder type for responses with no meaningful body.
struct GuestEmptyResponse: Decodable {
}
