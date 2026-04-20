import Foundation
import Glibc
import CLinuxVsock

/// Minimal HTTP/1.1-over-AF_VSOCK server.
///
/// Listens on `VMADDR_CID_ANY` + a fixed vsock port so the host
/// can reach us via `VZVirtioSocketDevice.connect(toPort:)`.
/// Spawns one thread per accepted connection — connection rate
/// is low (one host process per VM, long-lived streams) so a
/// full async event loop is overkill for this agent.
///
/// Wire format: the exact request/response shape the macOS agent
/// uses, so the host's `GuestAgentClient` doesn't notice which
/// OS answered.
final class VsockServer {

    private let port: UInt32
    private let router: Router

    init(port: UInt32, router: Router) {
        self.port = port
        self.router = router
    }

    func run() -> Never {
        let listenFD = bindAndListen()
        log("listening on vsock:\(port)")
        while true {
            var clientAddr = sockaddr_vm()
            var len = socklen_t(MemoryLayout<sockaddr_vm>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &len)
                }
            }
            guard clientFD >= 0 else {
                log("accept failed: \(String(cString: strerror(errno)))")
                continue
            }
            // One POSIX thread per connection. The alternative —
            // `DispatchQueue` — would work, but pthread gives
            // predictable stack sizes and the agent is memory-
            // sensitive inside small guest VMs.
            Thread.detachNewThread { [router] in
                defer { close(clientFD) }
                ConnectionHandler(fd: clientFD, router: router).serve()
            }
        }
    }

    private func bindAndListen() -> Int32 {
        let fd = socket(AF_VSOCK, Int32(SOCK_STREAM.rawValue), 0)
        precondition(fd >= 0, "socket(AF_VSOCK) failed: \(String(cString: strerror(errno)))")
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_cid = VMADDR_CID_ANY
        addr.svm_port = port
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        precondition(bindResult == 0, "bind vsock:\(port) failed: \(String(cString: strerror(errno)))")
        precondition(listen(fd, 32) == 0, "listen failed: \(String(cString: strerror(errno)))")
        return fd
    }
}

/// Serves a single accepted connection. Parses the request line
/// + headers, hands the path + query to the router, and writes
/// either a one-shot response or a streaming NDJSON body that
/// stays open until the client disconnects.
private final class ConnectionHandler {
    private let fd: Int32
    private let router: Router

    init(fd: Int32, router: Router) {
        self.fd = fd
        self.router = router
    }

    func serve() {
        guard let request = readRequest() else { return }
        switch router.route(method: request.method, path: request.path, query: request.query) {
        case .response(let status, let contentType, let body):
            writeResponse(status: status, contentType: contentType, body: body)
        case .stream(let stream):
            writeStreamHeader(contentType: "application/x-ndjson")
            stream.pump(writer: { [weak self] line in
                self?.writeChunk(line)
            })
        case .notFound:
            writeResponse(status: "404 Not Found", contentType: "text/plain", body: Data("not found\n".utf8))
        }
    }

    struct ParsedRequest {
        let method: String
        let path: String
        let query: String?
    }

    /// Reads just enough of the request to extract method + path
    /// + query. The agent has no POST-body endpoints in the
    /// minimal Linux surface, so we stop at the end of the
    /// header block.
    private func readRequest() -> ParsedRequest? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while buffer.count < 8 * 1024 {
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                read(fd, buf.baseAddress, buf.count)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk.prefix(n))
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: buffer, encoding: .utf8) else { return nil }
        guard let firstLine = text.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let rawTarget = String(parts[1])
        if let q = rawTarget.firstIndex(of: "?") {
            let path = String(rawTarget[..<q])
            let query = String(rawTarget[rawTarget.index(after: q)...])
            return ParsedRequest(method: method, path: path, query: query)
        }
        return ParsedRequest(method: method, path: rawTarget, query: nil)
    }

    private func writeResponse(status: String, contentType: String, body: Data) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        writeAll(Data(header.utf8))
        writeAll(body)
    }

    private func writeStreamHeader(contentType: String) {
        // Explicit `Transfer-Encoding: chunked` lets the host
        // parse each NDJSON line as it arrives without needing a
        // Content-Length up front.
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        writeAll(Data(header.utf8))
    }

    /// One chunked-encoding frame: size in hex + CRLF + payload
    /// + CRLF. Used for every NDJSON line on a streaming route.
    private func writeChunk(_ line: Data) {
        let size = String(line.count, radix: 16)
        writeAll(Data("\(size)\r\n".utf8))
        writeAll(line)
        writeAll(Data("\r\n".utf8))
    }

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { rawBuf -> Void in
            guard let base = rawBuf.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }
}
