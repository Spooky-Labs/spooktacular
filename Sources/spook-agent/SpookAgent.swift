/// The Spooktacular guest agent.
///
/// `spook-agent` is a minimal daemon that runs inside a macOS guest VM
/// and listens for provisioning scripts sent by the host over a VirtIO
/// socket (vsock). It implements the length-prefixed binary protocol
/// expected by ``VsockProvisioner``:
///
/// 1. Accept a connection on vsock port 9470.
/// 2. Read a 4-byte big-endian `UInt32` indicating the script length.
/// 3. Read exactly that many bytes of UTF-8 script content.
/// 4. Write the script to a temporary file and execute it with `/bin/bash`.
/// 5. Write the process exit code back as a 4-byte big-endian `UInt32`.
///
/// The agent loops forever, accepting one connection at a time, so it
/// can service multiple provisioning requests across the VM's lifetime.
///
/// ## Installation
///
/// Copy the binary to `/usr/local/bin/spook-agent` inside the guest and
/// install the companion LaunchDaemon plist so macOS starts it at boot:
///
/// ```bash
/// sudo cp spook-agent /usr/local/bin/spook-agent
/// sudo spook-agent --install-daemon
/// ```
///
/// ## Protocol Compatibility
///
/// The port number and wire format must match
/// `VsockProvisioner.agentPort` (9470) on the host side.

import Dispatch
import Foundation
import os

// MARK: - Constants

/// VirtIO socket address family on macOS.
private let AF_VSOCK: Int32 = 40

/// Accept connections from any CID (the host, or any peer).
private let VMADDR_CID_ANY: UInt32 = 0xFFFF_FFFF

/// The CID that always identifies the host.
private let VMADDR_CID_HOST: UInt32 = 2

/// The vsock port the agent listens on, matching ``VsockProvisioner/agentPort``.
private let agentPort: UInt32 = 9470

/// Logger for the guest agent.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "agent")

// MARK: - sockaddr_vm

/// The VirtIO socket address structure expected by `bind(2)`.
///
/// Layout must match the kernel's `struct sockaddr_vm`:
/// - `svm_len`:       size of the structure (UInt8)
/// - `svm_family`:    address family, always ``AF_VSOCK`` (UInt8)
/// - `svm_reserved1`: reserved, must be zero (UInt16)
/// - `svm_port`:      the vsock port number (UInt32)
/// - `svm_cid`:       the context ID to bind to (UInt32)
private struct sockaddr_vm {
    var svm_len: UInt8
    var svm_family: UInt8
    var svm_reserved1: UInt16
    var svm_port: UInt32
    var svm_cid: UInt32
}

// MARK: - Socket Helpers

/// Reads exactly `count` bytes from a file descriptor.
///
/// Retries on partial reads (which are normal for stream sockets) and
/// returns `nil` only if the peer closes the connection before all
/// bytes have been received.
///
/// - Parameters:
///   - fd: An open, connected file descriptor.
///   - count: The exact number of bytes to read.
/// - Returns: A `Data` value of exactly `count` bytes, or `nil` on failure.
private func readExact(fd: Int32, count: Int) -> Data? {
    var buffer = Data(count: count)
    var totalRead = 0
    while totalRead < count {
        let n = buffer.withUnsafeMutableBytes { ptr in
            read(fd, ptr.baseAddress!.advanced(by: totalRead), count - totalRead)
        }
        if n <= 0 { return nil }
        totalRead += n
    }
    return buffer
}

/// Writes all bytes in `data` to a file descriptor.
///
/// Retries on partial writes until every byte has been sent.
///
/// - Parameters:
///   - fd: An open, connected file descriptor.
///   - data: The bytes to write.
/// - Returns: `true` if all bytes were written, `false` on error.
@discardableResult
private func writeAll(fd: Int32, data: Data) -> Bool {
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

// MARK: - Connection Handler

/// Handles a single provisioning connection.
///
/// Reads the length-prefixed script, executes it with `/bin/bash`,
/// and writes the exit code back to the peer. The connection file
/// descriptor is closed before this function returns.
///
/// - Parameter clientFD: The accepted connection file descriptor.
private func handleConnection(_ clientFD: Int32) {
    defer { close(clientFD) }

    // 1. Read 4-byte big-endian script length.
    guard let lengthData = readExact(fd: clientFD, count: 4) else {
        log.error("Failed to read script length from host")
        return
    }
    let scriptLength = lengthData.withUnsafeBytes {
        UInt32(bigEndian: $0.load(as: UInt32.self))
    }

    guard scriptLength > 0, scriptLength < 10_000_000 else {
        log.error("Invalid script length: \(scriptLength)")
        return
    }

    // 2. Read script content.
    guard let scriptData = readExact(fd: clientFD, count: Int(scriptLength)) else {
        log.error("Failed to read script body (\(scriptLength) bytes)")
        return
    }

    guard let script = String(data: scriptData, encoding: .utf8) else {
        log.error("Script body is not valid UTF-8")
        return
    }

    log.info("Received script (\(scriptLength) bytes), executing")

    // 3. Write to a temp file and execute with /bin/bash.
    let exitCode = executeScript(script)

    // 4. Send 4-byte big-endian exit code.
    var response = exitCode.bigEndian
    let responseData = Data(bytes: &response, count: 4)
    if !writeAll(fd: clientFD, data: responseData) {
        log.error("Failed to send exit code to host")
    }

    log.info("Script finished with exit code \(exitCode)")
}

// MARK: - Script Execution

/// Writes a script to a temporary file and runs it with `/bin/bash`.
///
/// The temporary file is removed after execution completes.
///
/// - Parameter script: The shell script content to execute.
/// - Returns: The process termination status as a `UInt32`.
private func executeScript(_ script: String) -> UInt32 {
    let tempDir = FileManager.default.temporaryDirectory
    let scriptURL = tempDir.appendingPathComponent("spook-\(UUID().uuidString).sh")

    do {
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    } catch {
        log.error("Failed to write temp script: \(error.localizedDescription, privacy: .public)")
        return 1
    }

    defer { try? FileManager.default.removeItem(at: scriptURL) }

    // Make the script executable.
    chmod(scriptURL.path, 0o755)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [scriptURL.path]
    process.environment = ProcessInfo.processInfo.environment

    do {
        try process.run()
        process.waitUntilExit()
        return UInt32(process.terminationStatus)
    } catch {
        log.error("Failed to launch script: \(error.localizedDescription, privacy: .public)")
        return 1
    }
}

// MARK: - Entry Point

/// Parses command-line arguments and either installs the LaunchDaemon
/// or starts the agent loop.
@main
enum SpookAgent {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--install-daemon") {
            LaunchDaemon.install()
            return
        }

        runAgent()
    }

    /// Creates a vsock listener and loops forever accepting connections.
    ///
    /// Each connection is handled synchronously in ``handleConnection(_:)``.
    /// If the socket setup fails the process exits with status 1.
    private static func runAgent() -> Never {
        log.info("spook-agent starting on vsock port \(agentPort)")

        // 1. Create the vsock socket.
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            exit(1)
        }

        // Allow address reuse so restarts don't fail on TIME_WAIT.
        var optval: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &optval, socklen_t(MemoryLayout<Int32>.size))

        // 2. Bind to VMADDR_CID_ANY on the agent port.
        var addr = sockaddr_vm(
            svm_len: UInt8(MemoryLayout<sockaddr_vm>.size),
            svm_family: UInt8(AF_VSOCK),
            svm_reserved1: 0,
            svm_port: agentPort,
            svm_cid: VMADDR_CID_ANY
        )

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard bindResult == 0 else {
            log.error("bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            exit(1)
        }

        // 3. Listen with a small backlog (one provisioning session at a time).
        guard listen(fd, 4) == 0 else {
            log.error("listen() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            exit(1)
        }

        log.notice("Listening on vsock port \(agentPort)")

        // 4. Accept loop.
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

            // H23: Only accept connections from the host (CID 2).
            guard clientAddr.svm_cid == VMADDR_CID_HOST else {
                log.warning("Rejected connection from non-host CID \(clientAddr.svm_cid)")
                close(clientFD)
                continue
            }

            log.info("Accepted connection from CID \(clientAddr.svm_cid)")

            // H24: Dispatch to a background queue so the accept loop isn't blocked.
            DispatchQueue.global().async {
                handleConnection(clientFD)
            }
        }
    }
}
