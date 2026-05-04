import Darwin
import Dispatch
import Foundation
import os
import SpooktacularCore

/// TCP-over-vsock tunnel handler.
///
/// Runs inside the guest agent. When a host-side
/// ``PortForwarder`` connects on the tunnel vsock port (9473)
/// and sends `POST /api/v1/tunnel/<port>`, the router authorizes
/// the request, validates that `<port>` is a reasonable
/// destination, then invokes ``splice(vsockFD:guestPort:)`` to:
///
/// 1. Open an AF_INET stream socket inside the guest and
///    connect to `127.0.0.1:<guestPort>`.
/// 2. Write `HTTP/1.1 200 OK\r\n\r\n` back on the vsock to
///    signal "connection upgraded, bytes from here on are
///    tunnel payload" — standard HTTP CONNECT-style upgrade
///    semantics (RFC 7231 § 4.3.6).
/// 3. Splice bytes bidirectionally until either end closes.
///
/// Implementation notes:
///
/// - **Blocking syscalls on worker threads.** Each direction
///   of the splice runs on its own `DispatchQueue.global()`
///   block so a slow peer in one direction never starves the
///   other. Exit condition: `read()` returns 0 or < 0; we
///   then `shutdown(SHUT_WR)` the other side and close both
///   sockets.
/// - **Back-pressure via kernel socket buffers.** No
///   userspace buffering beyond the per-iteration 64 KB
///   stack buffer — the kernel's socket send buffer handles
///   flow control naturally.
/// - **No `sendfile`/`splice` syscall.** Darwin's `sendfile`
///   only moves file→socket; there's no kernel-level
///   socket-to-socket splice on macOS. `read` + `write`
///   through a 64 KB buffer is the canonical pattern and
///   kernel-residency keeps it fast enough for the
///   localhost→vsock path (the bottleneck is vsock, not
///   userspace copies).
enum TunnelHandler {

    private static let log = Logger(
        subsystem: "com.spooktacular.agent",
        category: "tunnel"
    )

    /// Maximum port number we'll dial into inside the guest.
    /// 65535 is the TCP ceiling; we reject 0 (not a real port)
    /// and the entire privileged range 1…1023 to close an
    /// obvious privilege-escalation path where a tunnel client
    /// would reach `localhost:22` (sshd) or `localhost:25`
    /// (sendmail) inside the VM without going through the
    /// normal mutual-auth + exec tooling.
    ///
    /// Override for testing by setting
    /// `SPOOKTACULAR_TUNNEL_ALLOW_PRIVILEGED=1` in the guest's
    /// environment.
    private static let privilegedPortCeiling: UInt16 = 1023

    /// Parses the target port from the tunnel-endpoint path and
    /// executes the splice. Called from
    /// ``AgentHTTPServer/handleConnection`` once `authorizeRequest`
    /// returns `.allowed` for a tunnel-scope request.
    ///
    /// - Parameters:
    ///   - vsockFD: The accepted vsock file descriptor. On
    ///     return this fd has been closed by the caller's
    ///     `defer`.
    ///   - path: The request path, e.g., `/api/v1/tunnel/8000`.
    ///   - allowPrivileged: When `true`, bypass the
    ///     `privilegedPortCeiling` check. Set by the caller
    ///     based on
    ///     `SPOOKTACULAR_TUNNEL_ALLOW_PRIVILEGED`.
    static func handle(
        vsockFD: Int32,
        path: String,
        allowPrivileged: Bool = false
    ) {
        guard let port = TunnelPath.parseGuestPort(from: path) else {
            writeResponse(fd: vsockFD, status: 400, body: "{\"error\":\"Bad Request: could not parse port from \(path)\"}")
            return
        }

        if !allowPrivileged && port <= privilegedPortCeiling {
            writeResponse(
                fd: vsockFD,
                status: 403,
                body: "{\"error\":\"Forbidden: tunnel to privileged port \(port) denied. Set SPOOKTACULAR_TUNNEL_ALLOW_PRIVILEGED=1 to override.\"}"
            )
            return
        }

        let targetFD = connectToGuestLocalhost(port: port)
        guard targetFD >= 0 else {
            let errStr = String(cString: strerror(errno))
            writeResponse(fd: vsockFD, status: 502, body: "{\"error\":\"Bad Gateway: \(errStr)\"}")
            return
        }

        // Signal the host that the tunnel is up. From this
        // byte forward the vsock carries raw payload.
        let ok = "HTTP/1.1 200 OK\r\nConnection: upgrade\r\n\r\n"
        guard writeAll(fd: vsockFD, data: Data(ok.utf8)) else {
            close(targetFD)
            return
        }

        log.info("Tunnel up → 127.0.0.1:\(port)")
        splice(a: vsockFD, b: targetFD)
        log.info("Tunnel closed → 127.0.0.1:\(port)")

        close(targetFD)
    }

    // MARK: - Socket helpers

    /// Opens an AF_INET stream socket in the guest and
    /// connects to `127.0.0.1:<port>`. Returns the fd, or `-1`
    /// on failure (errno preserved for the caller's error
    /// response).
    private static func connectToGuestLocalhost(port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    /// Bidirectional splice between two file descriptors.
    /// Blocks on the calling thread until EITHER side sees EOF
    /// or an unrecoverable error; shuts down the write-half of
    /// the opposite socket to propagate the half-close, then
    /// returns so the caller can close both fds.
    ///
    /// One background queue carries b→a; the calling thread
    /// handles a→b so we don't consume two dispatch threads
    /// when one is sufficient.
    static func splice(a: Int32, b: Int32) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            copy(src: b, dst: a)
            shutdown(a, SHUT_WR)
            done.signal()
        }
        copy(src: a, dst: b)
        shutdown(b, SHUT_WR)
        done.wait()
    }

    /// Single-direction byte pump with a 64 KB stack buffer.
    /// Matches what OpenSSH / netcat / socat use for the same
    /// purpose — bigger buffers hurt cache locality, smaller
    /// ones multiply syscalls.
    private static func copy(src: Int32, dst: Int32) {
        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let n = read(src, buffer, bufferSize)
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            if n == 0 { return }
            var written = 0
            while written < n {
                let w = write(dst, buffer.advanced(by: written), n - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    return
                }
                written += w
            }
        }
    }

    // MARK: - HTTP response helpers

    @discardableResult
    private static func writeAll(fd: Int32, data: Data) -> Bool {
        var total = 0
        let count = data.count
        while total < count {
            let n = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: total), count - total)
            }
            if n <= 0 { return false }
            total += n
        }
        return true
    }

    private static func writeResponse(fd: Int32, status: Int, body: String) {
        var header = "HTTP/1.1 \(status) \(statusText(for: status))\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.utf8.count)\r\n"
        header += "Connection: close\r\n"
        header += "\r\n"
        var response = Data(header.utf8)
        response.append(Data(body.utf8))
        writeAll(fd: fd, data: response)
    }

    private static func statusText(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 502: return "Bad Gateway"
        default:  return "Error"
        }
    }
}
