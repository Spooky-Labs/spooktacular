import Foundation
import Darwin
import SpooktacularCore

/// Apple-native guest-side dialer that pushes `GuestEvent`
/// frames to the host's `VZVirtioSocketListener` on port
/// `9469`.
///
/// The host ultimately reads these frames through
/// `AgentEventListener.events()`
/// (`AsyncThrowingStream<GuestEvent, Error>`). Wire format
/// matches `SpooktacularCore.AgentFrameCodec`: 4-byte
/// big-endian length prefix + `JSONEncoder`-produced
/// `GuestEvent` body, one frame at a time.
///
/// Why this exists alongside the HTTP router:
///
/// - The HTTP endpoints (exec, clipboard, apps, ports-RPC,
///   break-glass) are genuinely request/response, so HTTP is
///   a fine fit and staying there avoids rewriting 14+
///   handlers.
/// - The event stream is push-first (stats tick once per
///   second with no client ask) and matches Apple's
///   `VZVirtioSocketListener` delegate contract perfectly.
///   Running it on the Apple-native channel lets the chart
///   start populating as soon as the agent boots, without
///   the host's chart first having to probe
///   `connect(toPort:)`.
///
/// Reconnect: on any write or connect error we sleep and dial
/// again. The host's listener may be absent for a moment if
/// the VM's `start()` post-hook hasn't installed it yet; the
/// retry loop resolves the boot race without special cases.
final class HostEventDialer {

    /// Vsock port matching `AgentEventListener.listenerPort` on
    /// the host.
    static let eventPort: UInt32 = 9469

    /// macOS uses the same `VMADDR_CID_HOST = 2` as Linux.
    static let hostCID: UInt32 = 2

    static let reconnectDelay: TimeInterval = 2.0

    /// Starts the dialer on a detached thread. Returns
    /// immediately; the thread lives for the agent's lifetime.
    static func start() {
        Thread.detachNewThread {
            Self().run()
        }
    }

    private func run() {
        while true {
            let fd = connectOrNil()
            guard fd >= 0 else {
                Thread.sleep(forTimeInterval: Self.reconnectDelay)
                continue
            }
            pumpUntilDisconnect(fd: fd)
            close(fd)
            Thread.sleep(forTimeInterval: Self.reconnectDelay)
        }
    }

    private func connectOrNil() -> Int32 {
        // AF_VSOCK is available on macOS 11+ (Big Sur) via
        // `<sys/vsock.h>`. The Virtualization framework brings
        // it into user space for VM guests.
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_cid = Self.hostCID
        addr.svm_port = Self.eventPort
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        if rc != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func pumpUntilDisconnect(fd: Int32) {
        let encoder = JSONEncoder()
        while true {
            let response = GuestStatsResponse(
                cpuUsage: sampleCPUUsage(),
                memoryUsedBytes: sampleMemoryUsed(),
                memoryTotalBytes: sampleMemoryTotal(),
                loadAverage1m: sampleLoadAverage(),
                processCount: sampleProcessCount(),
                uptime: sampleUptime()
            )
            let event = GuestEvent.stats(response)
            guard let frame = try? AgentFrameCodec.encode(event, encoder: encoder) else { return }
            if !writeAll(fd: fd, data: frame) { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    private func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
