/// VirtIO socket (vsock) HTTP server for the spooktacular-agent.
///
/// ``AgentHTTPServer`` listens on a vsock port, accepts TCP-like
/// connections from the host, reads a complete HTTP/1.1 request,
/// routes it through ``routeRequest(_:)``, and writes the response.
///
/// Each connection is handled on a background `DispatchQueue` and
/// closed after a single request/response cycle (`Connection: close`).
/// The server loops forever on the calling thread once ``listen(port:)``
/// is invoked.
///
/// ## Architecture
///
/// The server reuses the same `sockaddr_vm` layout from the original
/// binary-protocol agent but replaces the wire format with HTTP/1.1.
/// This allows the host to talk to the agent using standard HTTP
/// clients over vsock.

import Dispatch
import Foundation
import os
import Synchronization
import SpooktacularApplication
import SpooktacularCore

/// The vsock-based HTTP server for the guest agent.
enum AgentHTTPServer {

    /// Logger for server lifecycle and connection events.
    private static let log = Logger(subsystem: "com.spooktacular.agent", category: "server")

    /// VirtIO socket address family on macOS.
    private static let AF_VSOCK: Int32 = 40

    /// Accept connections from any CID (host or peer).
    private static let VMADDR_CID_ANY: UInt32 = 0xFFFF_FFFF

    /// The CID that identifies the host.
    private static let VMADDR_CID_HOST: UInt32 = 2

    /// Maximum bytes to read from a single connection.
    ///
    /// 1 MB is generous for API requests -- the largest payload is
    /// file upload via Base64, which should still fit comfortably.
    private static let maxRequestSize = 1_048_576

    /// Kernel backlog depth for vsock `listen(2)`. Was previously 8,
    /// which bottlenecks concurrent boot-time probes from the host
    /// against the read-only port. 64 matches Darwin's typical
    /// upper bound for unprivileged daemons.
    private static let listenBacklog: Int32 = 64

    /// Maximum concurrent accepted connections the agent will
    /// process before returning `503 Service Unavailable` to new
    /// arrivals. A single runaway runner shouldn't be able to
    /// exhaust file descriptors on the tiny guest process.
    private static let maxConcurrentConnections = 128

    /// Per-read socket deadline in seconds. Applied via
    /// `SO_RCVTIMEO` / an elapsed-time check in ``readRequest(fd:)``
    /// so a slow-loris connection can't starve a handler thread.
    private static let readTimeoutSeconds: Int = 5

    /// Counter of currently-busy handler queues, protected
    /// by a [`Mutex`](https://developer.apple.com/documentation/synchronization/mutex)
    /// from Swift's `Synchronization` module — Apple's
    /// Sendable-by-construction replacement for the
    /// `nonisolated(unsafe) var` + `os_unfair_lock` pattern
    /// this static previously used.  `withLock` gives us
    /// the atomic check-then-increment the back-pressure
    /// gate needs in a single call.
    private static let activeConnections = Mutex<Int>(0)

    /// VirtIO socket address structure matching the kernel's `struct sockaddr_vm`.
    ///
    /// Name preserved verbatim from `<sys/vsock.h>` so the
    /// memory layout (checked by the subsequent `bind(2)`
    /// call) is unambiguously paired with the kernel's ABI.
    // swiftlint:disable:next type_name
    private struct sockaddr_vm {
        var svm_len: UInt8
        var svm_family: UInt8
        var svm_reserved1: UInt16
        var svm_port: UInt32
        var svm_cid: UInt32
    }

    /// Host-identity signature verifier. Enforces per-request
    /// P-256 signatures against the operator-provisioned trust
    /// allowlist on readonly + runner channels. `nil` → legacy
    /// no-auth mode (only valid when started without a trust
    /// dir; logged as a warning at startup).
    ///
    /// Set exactly once before the accept loop begins and never
    /// mutated afterward so concurrent reads from
    /// connection-handler queues are safe.
    nonisolated(unsafe) static var signatureVerifier: SignedRequestVerifier?

    /// The OWASP-aligned break-glass ticket verifier, or `nil` if
    /// the agent is running without ticket support.
    ///
    /// When non-`nil`, authorization headers starting with the
    /// `bgt:` prefix go through single-use P-256 ticket
    /// verification on the break-glass channel. See
    /// ``BreakGlassTicketVerifier`` for the threat model.
    nonisolated(unsafe) static var ticketVerifier: BreakGlassTicketVerifier?

    /// Starts three vsock HTTP listeners in parallel — one per capability tier.
    ///
    /// Each listener binds to a separate vsock port and enforces a maximum
    /// ``EndpointScope`` at the transport layer. Requests whose endpoint
    /// scope exceeds the channel scope are rejected with 403 before token
    /// authentication is even attempted.
    ///
    /// | Port | Channel | Max Scope |
    /// |------|---------|-----------|
    /// | `readonlyPort`   | Read-only      | `.readonly`   |
    /// | `runnerPort`     | Runner control | `.runner`     |
    /// | `breakGlassPort` | Break-glass    | `.breakGlass` |
    ///
    /// The read-only and runner listeners run on background dispatch
    /// queues; the break-glass listener blocks the calling thread.
    ///
    /// - Parameters:
    ///   - readonlyPort: The vsock port for the read-only channel (default: 9470).
    ///   - runnerPort: The vsock port for the runner channel (default: 9471).
    ///   - breakGlassPort: The vsock port for the break-glass channel (default: 9472).
    /// - Returns: Never returns; loops until the process is terminated.
    ///
    /// Before calling this, set ``signatureVerifier`` and /or
    /// ``ticketVerifier``. At least one must be configured unless
    /// the agent is deliberately running in legacy no-auth mode
    /// (a warning should be logged at startup in that case).
    static func listenAll(
        readonlyPort: UInt32 = 9470,
        runnerPort: UInt32 = 9471,
        breakGlassPort: UInt32 = 9472,
        tunnelPort: UInt32 = 9473
    ) -> Never {
        log.notice("Starting multi-channel vsock listeners: readonly=\(readonlyPort), runner=\(runnerPort), breakGlass=\(breakGlassPort), tunnel=\(tunnelPort)")

        // Start read-only, runner, and tunnel listeners on
        // background queues. Break-glass blocks the main
        // thread below so the process never exits.
        DispatchQueue.global(qos: .default).async {
            acceptLoop(port: readonlyPort, channelScope: .readonly)
        }
        DispatchQueue.global(qos: .default).async {
            acceptLoop(port: runnerPort, channelScope: .runner)
        }
        DispatchQueue.global(qos: .default).async {
            acceptLoop(port: tunnelPort, channelScope: .tunnel)
        }

        // Block the main thread on the break-glass listener.
        acceptLoop(port: breakGlassPort, channelScope: .breakGlass)
    }

    /// Starts the vsock HTTP server on a single port and blocks forever.
    ///
    /// Creates a vsock socket, binds to the given port, and enters
    /// an accept loop. Each accepted connection is dispatched to a
    /// background queue for HTTP parsing and routing.
    ///
    /// This is the legacy single-port entry point. For multi-channel
    /// isolation, prefer ``listenAll(readonlyPort:runnerPort:breakGlassPort:)``.
    ///
    /// - Parameters:
    ///   - port: The vsock port to listen on (default: 9470).
    ///   - channelScope: The maximum ``EndpointScope`` allowed on this channel.
    ///     Defaults to `.breakGlass` for backward compatibility.
    /// - Returns: Never returns; loops until the process is terminated.
    static func listen(
        port: UInt32 = 9470,
        channelScope: EndpointScope = .breakGlass
    ) -> Never {
        acceptLoop(port: port, channelScope: channelScope)
    }

    /// Binds a vsock socket and enters the accept loop. Blocks forever.
    ///
    /// - Parameters:
    ///   - port: The vsock port to bind.
    ///   - channelScope: The maximum ``EndpointScope`` for connections on this port.
    private static func acceptLoop(port: UInt32, channelScope: EndpointScope) -> Never {
        log.info("Starting HTTP server on vsock port \(port) (scope: \(channelScope.debugLabel, privacy: .public))")

        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            exit(1)
        }

        var optval: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_vm(
            svm_len: UInt8(MemoryLayout<sockaddr_vm>.size),
            svm_family: UInt8(AF_VSOCK),
            svm_reserved1: 0,
            svm_port: port,
            svm_cid: VMADDR_CID_ANY
        )

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bindResult == 0 else {
            log.error("bind() failed on port \(port): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            exit(1)
        }

        guard Darwin.listen(fd, listenBacklog) == 0 else {
            log.error("listen() failed on port \(port): \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            exit(1)
        }

        log.notice("Listening on vsock port \(port) (scope: \(channelScope.debugLabel, privacy: .public), backlog: \(listenBacklog))")

        while true {
            var clientAddr = sockaddr_vm(
                svm_len: 0, svm_family: 0, svm_reserved1: 0, svm_port: 0, svm_cid: 0
            )
            var clientLen = socklen_t(MemoryLayout<sockaddr_vm>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(fd, sa, &clientLen)
                }
            }

            guard clientFD >= 0 else {
                log.error("accept() failed: \(String(cString: strerror(errno)), privacy: .public)")
                continue
            }

            guard clientAddr.svm_cid == VMADDR_CID_HOST else {
                log.warning("Rejected connection from non-host CID \(clientAddr.svm_cid)")
                close(clientFD)
                continue
            }

            // Set a read timeout via SO_RCVTIMEO so read(2) returns
            // EAGAIN after `readTimeoutSeconds` instead of blocking
            // indefinitely on a slow-loris peer. Apple POSIX docs:
            // developer.apple.com/library/archive/documentation/NetworkingInternetWeb
            var rcvTimeout = timeval(tv_sec: readTimeoutSeconds, tv_usec: 0)
            setsockopt(
                clientFD, SOL_SOCKET, SO_RCVTIMEO,
                &rcvTimeout, socklen_t(MemoryLayout<timeval>.size)
            )

            // Connection-limit back-pressure. Respond with 503 and
            // close; don't spawn a handler queue (which is the
            // resource we're trying to protect).  `withLock`
            // returns a tuple of the decision + the observed
            // count so we can log the count after releasing
            // the lock without a second acquisition.
            let (accepted, observedCount) = activeConnections.withLock { count -> (Bool, Int) in
                if count < maxConcurrentConnections {
                    count += 1
                    return (true, count)
                } else {
                    return (false, count)
                }
            }
            guard accepted else {
                let body = Data("{\"error\":\"Service unavailable: agent at capacity.\"}".utf8)
                let response = buildRawResponse(statusCode: 503, body: body)
                writeAll(fd: clientFD, data: response)
                close(clientFD)
                log.warning("Rejected connection: active=\(observedCount) cap=\(maxConcurrentConnections)")
                continue
            }

            log.info("Accepted connection from CID \(clientAddr.svm_cid) on port \(port)")

            let scope = channelScope
            DispatchQueue.global().async {
                defer {
                    activeConnections.withLock { $0 -= 1 }
                }
                handleConnection(clientFD, channelScope: scope)
            }
        }
    }

    /// Outcome of a bounded-time read attempt on a client socket.
    enum ReadOutcome: Sendable {
        /// The complete request data, bounded by `maxRequestSize`.
        case data(Data)
        /// Read budget exhausted — return 408 Request Timeout.
        case timedOut
        /// Request exceeded ``maxRequestSize`` — return 413.
        case tooLarge
        /// Connection closed before any bytes arrived, or read errored.
        case closed
    }

    /// Handles a single HTTP connection: read, parse, route, respond, close.
    ///
    /// - Parameters:
    ///   - fd: The accepted client file descriptor.
    ///   - channelScope: The maximum ``EndpointScope`` for this connection's
    ///     vsock channel. Passed through to ``routeRequest(_:channelScope:signatureVerifier:ticketVerifier:)``
    ///     so endpoints exceeding the channel scope are rejected with 403.
    private static func handleConnection(_ fd: Int32, channelScope: EndpointScope = .breakGlass) {
        defer { close(fd) }

        let outcome = readRequest(fd: fd, deadlineSeconds: readTimeoutSeconds)
        let requestData: Data
        switch outcome {
        case .data(let d):
            requestData = d
        case .timedOut:
            let body = Data("{\"error\":\"Request timed out.\"}".utf8)
            writeAll(fd: fd, data: buildRawResponse(statusCode: 408, body: body))
            log.warning("Read deadline exceeded — closing connection")
            return
        case .tooLarge:
            let body = Data("{\"error\":\"Payload too large.\"}".utf8)
            writeAll(fd: fd, data: buildRawResponse(statusCode: 413, body: body))
            log.warning("Request exceeded maxRequestSize — closing connection")
            return
        case .closed:
            log.error("Failed to read request data")
            return
        }

        let request: AgentHTTPRequest
        do {
            request = try AgentHTTPParser.parse(requestData)
        } catch {
            log.error("Failed to parse HTTP request: \(error.localizedDescription, privacy: .public)")
            let body = Data("{\"error\":\"Malformed HTTP request.\"}".utf8)
            let response = buildRawResponse(statusCode: 400, body: body)
            writeAll(fd: fd, data: response)
            return
        }

        log.info("\(request.method, privacy: .public) \(request.path, privacy: .public)")

        // Streaming endpoints: bypass the request → response ping-pong
        // and keep the connection open, writing newline-delimited
        // JSON frames until the client disconnects. The only one
        // today is `/api/v1/stats/stream` — real-time VM metrics
        // pushed from the guest so the host-side UI never polls.
        //
        // Run the full auth gate first — ``authorizeRequest`` is
        // the same helper ``routeRequest`` uses, so channel-scope
        // isolation, signature verification, and tier enforcement
        // all apply before we upgrade the socket to a stream. On
        // denial the helper returns a fully serialized error
        // response; we write it and close like any other 4xx.
        // Events stream: one vsock connection, many topics,
        // NDJSON framing. Replaces the legacy single-purpose
        // `/api/v1/stats/stream`. Client subscribes once via
        // `?topics=stats,ports,apps.frontmost` (absent query
        // means all topics). Matches GhostVM's `/api/v1/events`
        // shape — one persistent connection, tagged frames,
        // graceful forward-compatibility when the server
        // supports topics the client doesn't yet know.
        if request.method == "GET", request.path.hasPrefix("/api/v1/events/stream") {
            switch authorizeRequest(
                request,
                channelScope: channelScope,
                signatureVerifier: signatureVerifier,
                ticketVerifier: ticketVerifier
            ) {
            case .allowed:
                let filter = GuestEventFilter.parse(request.query["topics"])
                streamEventsForever(fd: fd, filter: filter)
            case .denied(let errorBytes):
                writeAll(fd: fd, data: errorBytes)
            }
            return
        }

        // Tunnel endpoint: `POST /api/v1/tunnel/<port>`. Like
        // the stats-stream upgrade above, this bypasses the
        // normal request→response router after auth succeeds
        // and hands the raw fd to `TunnelHandler.handle` for
        // bidirectional TCP splicing. The auth gate reuses the
        // identical `authorizeRequest` helper so a leaked
        // tunnel credential can't reach any other endpoint and
        // vice versa — the same channel-scope and tier-scope
        // checks that guard REST endpoints also guard tunnels.
        if request.method == "POST", request.path.hasPrefix("/api/v1/tunnel/") {
            switch authorizeRequest(
                request,
                channelScope: channelScope,
                signatureVerifier: signatureVerifier,
                ticketVerifier: ticketVerifier
            ) {
            case .allowed:
                let allowPrivileged = ProcessInfo.processInfo
                    .environment["SPOOKTACULAR_TUNNEL_ALLOW_PRIVILEGED"] == "1"
                TunnelHandler.handle(
                    vsockFD: fd,
                    path: request.path,
                    allowPrivileged: allowPrivileged
                )
            case .denied(let errorBytes):
                writeAll(fd: fd, data: errorBytes)
            }
            return
        }

        let response = routeRequest(
            request,
            channelScope: channelScope,
            signatureVerifier: signatureVerifier,
            ticketVerifier: ticketVerifier
        )
        writeAll(fd: fd, data: response)
    }

    /// Writes tagged NDJSON (`application/x-ndjson`) frames
    /// for every ``GuestEvent`` topic the subscriber's
    /// `filter` permits. Replaces the legacy
    /// `streamStatsForever` — unified producer, tagged
    /// frames, one loop.
    ///
    /// Each iteration produces at most one frame per topic.
    /// We gate the outer sleep on the shortest per-topic
    /// cadence (1 s today — stats). Topics that change less
    /// frequently (ports, apps.frontmost) emit only on change,
    /// so a quiet VM sees just heartbeat-free stats frames
    /// while a busy one sees the full fan-out.
    ///
    /// Returns when a write fails (client disconnected) — the
    /// enclosing `handleConnection` closes the fd in its
    /// `defer`.
    ///
    /// Wire docs:
    /// - HTTP/1.1 semantics: https://datatracker.ietf.org/doc/html/rfc7230
    /// - NDJSON spec: https://github.com/ndjson/ndjson-spec
    /// - `GuestEvent` Codable envelope: ``SpooktacularCore/GuestEvent``
    private static func streamEventsForever(fd: Int32, filter: GuestEventFilter) {
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/x-ndjson",
            "Cache-Control: no-cache",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        guard writeAll(fd: fd, data: Data(headers.utf8)) else { return }

        let encoder = JSONEncoder()

        // Topic-cadence state: we want `.stats` every tick
        // (1 Hz) but `.ports` / `.appsFrontmost` only on
        // change. Hold the last-seen values so we can diff.
        var lastPorts: [GuestPortInfo]?
        var lastFrontmost: GuestAppInfo?

        while true {
            if filter.allows(topic: GuestEventFilter.statsTopic) {
                let event = GuestEvent.stats(currentStatsSnapshot())
                if !writeFrame(fd: fd, event: event, encoder: encoder) { return }
            }

            if filter.allows(topic: GuestEventFilter.portsTopic) {
                let sample = currentPortsSnapshot()
                if sample != lastPorts {
                    lastPorts = sample
                    let event = GuestEvent.ports(sample)
                    if !writeFrame(fd: fd, event: event, encoder: encoder) { return }
                }
            }

            if filter.allows(topic: GuestEventFilter.appsFrontmostTopic) {
                let sample = currentFrontmostApp()
                if sample != lastFrontmost {
                    lastFrontmost = sample
                    let event = GuestEvent.appsFrontmost(sample)
                    if !writeFrame(fd: fd, event: event, encoder: encoder) { return }
                }
            }

            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Encodes + writes a single NDJSON frame, returning
    /// `false` when the write fails (client gone, EPIPE,
    /// etc.) so the caller can abort the stream loop.
    private static func writeFrame(
        fd: Int32,
        event: GuestEvent,
        encoder: JSONEncoder
    ) -> Bool {
        guard let json = try? encoder.encode(event) else { return true }
        var frame = json
        frame.append(0x0A)  // '\n'
        return writeAll(fd: fd, data: frame)
    }

    /// Builds a `GuestStatsResponse` from the current
    /// host_processor_info + host_statistics64 samples. Same
    /// source `AgentStatsHandler.handleStats` uses — keep
    /// these two call sites in sync.
    private static func currentStatsSnapshot() -> GuestStatsResponse {
        GuestStatsResponse(
            cpuUsage: sampleCPUUsage(),
            memoryUsedBytes: sampleMemoryUsed(),
            memoryTotalBytes: sampleMemoryTotal(),
            loadAverage1m: sampleLoadAverage(),
            processCount: sampleProcessCount(),
            uptime: sampleUptime()
        )
    }

    /// Snapshots listening TCP ports via the same `lsof` path
    /// ``handleListPorts`` uses. Kept in this file for
    /// proximity to the event loop; the logic itself is
    /// shared lsof parsing. An empty result means "nothing
    /// listens right now" — a legitimate state that we DO
    /// want to publish so clients can wipe their port UI.
    private static func currentPortsSnapshot() -> [GuestPortInfo] {
        handleListPortsSnapshot()
    }

    /// Snapshots the current frontmost `NSRunningApplication`.
    /// Returns `nil` on Recovery mode or other edge states
    /// where the WindowServer has no foreground app.
    private static func currentFrontmostApp() -> GuestAppInfo? {
        handleFrontmostAppSnapshot()
    }

    /// Reads up to ``maxRequestSize`` bytes from a file descriptor,
    /// enforcing a total-elapsed-time deadline at every read boundary.
    ///
    /// `SO_RCVTIMEO` set in the accept loop backs each individual
    /// `read(2)` with a kernel-level timeout. This method layers a
    /// second check on total elapsed wall time so even a sequence
    /// of just-under-timeout reads cannot extend past the deadline.
    ///
    /// - Parameters:
    ///   - fd: An open, connected file descriptor.
    ///   - deadlineSeconds: Total seconds allowed for the complete
    ///     request to arrive.
    /// - Returns: A ``ReadOutcome`` describing the read result.
    static func readRequest(fd: Int32, deadlineSeconds: Int) -> ReadOutcome {
        var buffer = Data(capacity: 65536)
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { readBuffer.deallocate() }

        let clock = ContinuousClock()
        let start = clock.now
        let deadline: Duration = .seconds(deadlineSeconds)

        while buffer.count < maxRequestSize {
            if clock.now - start > deadline {
                return .timedOut
            }

            let n = read(fd, readBuffer, 65536)
            if n < 0 {
                // EAGAIN/EWOULDBLOCK from SO_RCVTIMEO → treat as a
                // timeout and surface 408 (rather than the previous
                // silent close).
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return .timedOut
                }
                if errno == EINTR { continue }
                return buffer.isEmpty ? .closed : .data(buffer)
            }
            if n == 0 { break }
            buffer.append(readBuffer, count: n)

            // If we got less than a full buffer, the request is likely complete.
            if n < 65536 { break }

            // Bounce the ceiling: `while` condition re-checks at top,
            // but we also guard against the exact-size boundary case
            // where a 1-MiB body arrives in one full read.
            if buffer.count >= maxRequestSize { return .tooLarge }
        }

        if buffer.count >= maxRequestSize { return .tooLarge }
        return buffer.isEmpty ? .closed : .data(buffer)
    }

    /// Writes all bytes to a file descriptor, retrying on partial writes.
    ///
    /// - Parameters:
    ///   - fd: An open, connected file descriptor.
    ///   - data: The bytes to write.
    @discardableResult
    private static func writeAll(fd: Int32, data: Data) -> Bool {
        var totalWritten = 0
        let count = data.count
        while totalWritten < count {
            let n = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: totalWritten), count - totalWritten)
            }
            if n <= 0 { return false }
            totalWritten += n
        }
        return true
    }

    /// Builds a minimal HTTP response for error cases before routing.
    private static func buildRawResponse(statusCode: Int, body: Data) -> Data {
        var header = "HTTP/1.1 \(statusCode) Error\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }
}
