import Foundation
import Darwin
import SpiceProtocol

/// Errors thrown by serial-port operations.
public enum SpiceSerialPortError: Error, Equatable, Sendable, LocalizedError {
    /// `open(2)` on the device returned -1. `errno` is
    /// included verbatim so callers can log / branch on
    /// `ENOENT` (port missing — VZ probably didn't configure
    /// `VZSpiceAgentPortAttachment`), `EBUSY` (another agent
    /// already has the port), `EACCES` (sandbox denied).
    case openFailed(path: String, errno: Int32)

    /// `tcgetattr` / `tcsetattr` failed. Rare — only happens
    /// when the fd isn't a tty, which shouldn't occur on
    /// `/dev/tty.com.redhat.spice.0`, but we surface a clear
    /// error anyway so nobody debugs line-discipline silently.
    case termiosFailed(errno: Int32)

    /// `write(2)` returned -1. `errno` indicates the cause —
    /// `EPIPE` is the most common (host detached the port
    /// because the VM was stopped).
    case writeFailed(errno: Int32)

    /// `read(2)` returned -1 for a non-recoverable reason
    /// (neither `EAGAIN` nor `EINTR`). Same errno semantics
    /// as ``writeFailed``.
    case readFailed(errno: Int32)

    /// The peer closed the channel cleanly (read returned 0).
    case peerClosed

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let errno):
            return "Failed to open SPICE serial port \(path): \(errnoMessage(errno))."
        case .termiosFailed(let errno):
            return "Failed to configure SPICE serial port termios: \(errnoMessage(errno))."
        case .writeFailed(let errno):
            return "SPICE serial port write failed: \(errnoMessage(errno))."
        case .readFailed(let errno):
            return "SPICE serial port read failed: \(errnoMessage(errno))."
        case .peerClosed:
            return "SPICE serial port peer closed the channel (EOF)."
        }
    }
}

private func errnoMessage(_ code: Int32) -> String {
    "errno \(code) (\(String(cString: strerror(code))))"
}

/// Thin POSIX wrapper around the virtio-serial device.
///
/// Owns the file descriptor for its lifetime; `close()` is
/// idempotent and always safe to call. Intentionally not an
/// `actor` — it's a leaf-level type with no mutable state
/// other than the fd, and the `SpiceTransport` actor above it
/// is the concurrency boundary.
///
/// ## Why a custom wrapper instead of `FileHandle`
///
/// `FileHandle.bytes` works on regular files and pipes, but
/// on a tty it gives us a byte-at-a-time async sequence with
/// no framing hook — we'd have to buffer+reframe ourselves in
/// application code. `DispatchSource.makeReadSource` lets us
/// consume whatever the kernel hands us in each read in one
/// go, which is a closer fit to SPICE's self-describing
/// length-prefixed framing.
///
/// Also: `FileHandle` on a non-regular fd has had subtle
/// closure-behaviour bugs across macOS releases; the
/// POSIX-direct path is more predictable.
public final class SpiceSerialPort: @unchecked Sendable {

    /// Default guest-side SPICE port path.
    /// `VZSpiceAgentPortAttachment.spiceAgentPortName` resolves
    /// to `"com.redhat.spice.0"` and Apple's VZ guest runtime
    /// exposes the virtio-console port at
    /// `/dev/tty.<portName>`.
    public static let defaultDevicePath = "/dev/tty.com.redhat.spice.0"

    public let fileDescriptor: Int32
    public let devicePath: String

    private var closed = false
    private let closeLock = NSLock()

    /// Opens the device and puts it into raw mode.
    ///
    /// Flags:
    /// - `O_RDWR` — single bidirectional fd (virtio-serial on
    ///   macOS is one channel, both ways).
    /// - `O_NONBLOCK` — reads/writes return immediately with
    ///   `EAGAIN` when there's no data / no room. The dispatch
    ///   source layer above handles back-pressure.
    /// - `O_NOCTTY` — do NOT let this tty become our process's
    ///   controlling terminal. Critical for a daemon / menu-bar
    ///   agent: the default `open()` behaviour on a tty would
    ///   otherwise re-parent us to the tty's session.
    ///
    /// Termios:
    /// - `cfmakeraw(&term)` zeros every line-discipline flag
    ///   (ICANON, ECHO, ISIG, IXON, etc.), leaving us with
    ///   clean byte-stream semantics — the tty becomes
    ///   indistinguishable from a pipe for binary framing.
    /// - `VMIN = 1 / VTIME = 0` — `read()` returns as soon as
    ///   at least one byte is available, without a timeout.
    ///   Paired with `O_NONBLOCK`, the dispatch source wakes
    ///   us up whenever bytes arrive; `read()` then drains
    ///   whatever the kernel has queued.
    public init(devicePath: String = SpiceSerialPort.defaultDevicePath) throws {
        self.devicePath = devicePath
        let fd = devicePath.withCString { cstr in
            Darwin.open(cstr, O_RDWR | O_NONBLOCK | O_NOCTTY)
        }
        guard fd >= 0 else {
            throw SpiceSerialPortError.openFailed(
                path: devicePath,
                errno: errno
            )
        }
        self.fileDescriptor = fd

        // Configure termios. tcgetattr/tcsetattr can in theory
        // fail with ENOTTY on a non-tty fd — shouldn't happen
        // on a virtio-console device, but we surface it
        // explicitly rather than silently shipping half-configured.
        var term = termios()
        if tcgetattr(fd, &term) != 0 {
            let err = errno
            Darwin.close(fd)
            throw SpiceSerialPortError.termiosFailed(errno: err)
        }
        cfmakeraw(&term)
        // Satisfy the compiler: `c_cc` is a fixed-size tuple
        // in the imported termios struct. Use the MIN/TIME
        // indexes directly rather than the symbolic names,
        // which don't bridge cleanly to Swift.
        term.c_cc.16 = 1  // VMIN  — one-byte minimum read
        term.c_cc.17 = 0  // VTIME — zero inter-byte timeout
        if tcsetattr(fd, TCSANOW, &term) != 0 {
            let err = errno
            Darwin.close(fd)
            throw SpiceSerialPortError.termiosFailed(errno: err)
        }
    }

    /// Writes `data` to the device, retrying on `EAGAIN` /
    /// `EINTR`. Returns when every byte has been flushed into
    /// the kernel's virtio-serial TX queue.
    ///
    /// Called from the write-serializing `SpiceTransport`
    /// actor, so multiple concurrent callers can't interleave
    /// bytes — this method assumes it's the only writer in
    /// flight.
    public func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var remaining = buffer.count
            var pointer = base
            while remaining > 0 {
                let written = Darwin.write(fileDescriptor, pointer, remaining)
                if written > 0 {
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                    continue
                }
                // `write() == 0` on a non-blocking fd
                // effectively means "try again" for a stream
                // device — treat same as EAGAIN.
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
                    // Busy-wait is acceptable in burst writes
                    // for small clipboard payloads (<= a few
                    // MiB). If we ever support huge images
                    // we'd switch to dispatch-source–driven
                    // write readiness.
                    usleep(1000)
                    continue
                }
                throw SpiceSerialPortError.writeFailed(errno: err)
            }
        }
    }

    /// Reads up to `maxBytes` into a new `Data`. Returns an
    /// empty `Data` when the fd is temporarily drained
    /// (`EAGAIN`) — the dispatch source will fire again when
    /// more bytes arrive. Throws ``SpiceSerialPortError/peerClosed``
    /// on EOF and ``SpiceSerialPortError/readFailed`` on any
    /// other error.
    public func read(maxBytes: Int = 64 * 1024) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = buffer.withUnsafeMutableBufferPointer { ptr -> ssize_t in
            Darwin.read(fileDescriptor, ptr.baseAddress, ptr.count)
        }
        if n > 0 {
            return Data(buffer.prefix(n))
        }
        if n == 0 {
            throw SpiceSerialPortError.peerClosed
        }
        let err = errno
        if err == EAGAIN || err == EWOULDBLOCK || err == EINTR {
            return Data()  // drained for now; caller waits
        }
        throw SpiceSerialPortError.readFailed(errno: err)
    }

    /// Idempotent. Safe to call from any thread.
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !closed else { return }
        closed = true
        _ = Darwin.close(fileDescriptor)
    }

    deinit {
        // Safe to call unconditionally; close() above is
        // idempotent behind a lock.
        close()
    }
}
