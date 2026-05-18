import Foundation
import Glibc
import CLinuxVsock

/// Dials `VMADDR_CID_HOST:9469` (the Apple-native host listener)
/// and pushes length-prefixed `GuestEvent`-shaped JSON frames
/// until the connection drops.
///
/// Apple's `Virtualization.framework` runs a
/// `VZVirtioSocketListener` on the host side; this class is the
/// matching guest-side dialer. The wire format is the one
/// `SpooktacularCore.AgentFrameCodec` defines: 4-byte
/// big-endian length + `JSONEncoder` body.
///
/// Reconnection policy: on any write/connect error we sleep
/// briefly and dial again. The host may not have the listener
/// set up yet at guest boot (systemd can beat
/// `VirtualMachine.start()`'s post-start hook by a few hundred
/// ms); reconnect-forever keeps the agent honest without
/// special-casing the race.
final class HostDialer {

    /// Apple-native event channel port. Matches
    /// `AgentEventListener.listenerPort` on the host.
    static let eventPort: UInt32 = 9469

    /// vsock CID for the host. Constant from
    /// <linux/vm_sockets.h>.
    static let hostCID: UInt32 = 2

    /// Seconds between reconnect attempts. Short enough that the
    /// post-boot race resolves quickly, long enough that a truly
    /// absent host (guest is running without its host app) doesn't
    /// spin the CPU.
    static let reconnectDelay: TimeInterval = 2.0

    private let stats: StatsCoordinator

    init(stats: StatsCoordinator) {
        self.stats = stats
    }

    func run() -> Never {
        while true {
            let fd = connectOrNil()
            guard fd >= 0 else {
                Thread.sleep(forTimeInterval: Self.reconnectDelay)
                continue
            }
            log("connected to host listener on vsock:\(Self.eventPort)")
            pumpUntilDisconnect(fd: fd)
            close(fd)
            log("host connection dropped — reconnecting in \(Self.reconnectDelay)s")
            Thread.sleep(forTimeInterval: Self.reconnectDelay)
        }
    }

    // MARK: - Connect

    private func connectOrNil() -> Int32 {
        let fd = socket(AF_VSOCK, Int32(SOCK_STREAM.rawValue), 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_cid = Self.hostCID
        addr.svm_port = Self.eventPort
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Glibc.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    // MARK: - Frame pump

    private func pumpUntilDisconnect(fd: Int32) {
        while true {
            // Emit one stats frame per tick. When we add more
            // topics (ports, apps.frontmost), each gets its own
            // frame on the same socket.
            let frame = stats.snapshot()
            let event: AgentFrame = .stats(
                Stats(
                    cpuUsage: frame.cpuUsage,
                    memoryUsedBytes: frame.memoryUsedBytes,
                    memoryTotalBytes: frame.memoryTotalBytes,
                    loadAverage1m: frame.loadAverage1m,
                    processCount: frame.processCount,
                    uptime: frame.uptime
                )
            )
            guard let payload = try? JSONEncoder().encode(event) else { return }
            guard writeFrame(fd: fd, payload: payload) else { return }
            Thread.sleep(forTimeInterval: 1.0)
        }
    }

    /// Writes one length-prefixed frame. Returns `false` if the
    /// host closed or there was a write error — the caller
    /// reconnects.
    private func writeFrame(fd: Int32, payload: Data) -> Bool {
        var header = UInt32(payload.count).bigEndian
        let headerOK = withUnsafeBytes(of: &header) { buf in
            writeAll(fd: fd, bytes: buf)
        }
        guard headerOK else { return false }
        return payload.withUnsafeBytes { buf in
            writeAll(fd: fd, bytes: buf)
        }
    }

    private func writeAll(fd: Int32, bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress else { return true }
        var sent = 0
        while sent < bytes.count {
            let n = write(fd, base.advanced(by: sent), bytes.count - sent)
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}

// MARK: - Wire-compatible envelope

/// Mirrors `SpooktacularCore.GuestEvent` on the wire so the
/// host's Codable decoder works without any per-agent shim.
/// The envelope uses `topic`/`data` keys per `GuestEvent`'s
/// Codable extension.
enum AgentFrame: Encodable {
    case stats(Stats)
    case ports([Port])

    private enum CodingKeys: String, CodingKey { case topic, data }
    private enum Topic: String, Encodable { case stats, ports }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .stats(let payload):
            try container.encode(Topic.stats, forKey: .topic)
            try container.encode(payload, forKey: .data)
        case .ports(let payload):
            try container.encode(Topic.ports, forKey: .topic)
            try container.encode(payload, forKey: .data)
        }
    }
}

struct Stats: Encodable {
    // Field names must match `GuestStatsResponse` on the host.
    let cpuUsage: Double?
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let loadAverage1m: Double
    let processCount: Int
    let uptime: TimeInterval
}

struct Port: Encodable {
    // Matches `GuestPortInfo` on the host.
    let port: UInt16
    let pid: Int32
    let processName: String
}
