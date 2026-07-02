import Foundation
import Darwin
import os
import SpooktacularCore

/// Apple-native guest-side dialer that pushes `GuestEvent`
/// frames to the host's `VZVirtioSocketListener` on port
/// `9469`.
///
/// The host reads these frames through
/// `AgentEventListener.events()`
/// (`AsyncThrowingStream<GuestEvent, Error>`). Wire format
/// matches `SpooktacularCore.AgentFrameCodec`: 4-byte
/// big-endian length prefix + `JSONEncoder`-produced
/// `GuestEvent` body, one frame at a time.
///
/// ## Event sources
///
/// The dialer multiplexes two kinds of events onto the same
/// vsock connection:
///
/// 1. **Periodic stats** — sampled every 1 s from the guest's
///    kernel metrics. Always emitted by this module itself.
/// 2. **On-change events** posted by other subsystems via
///    ``post(_:)``. Today's examples:
///    - ``SpooktacularGuestAgentCore/SpiceStatusProvider``-
///      backed SPICE-clipboard status changes (pushed by the
///      guest-tools app's `AgentController`).
///    Future ports-on-change + frontmost-app events will
///    flow through the same path.
///
/// ## Reconnect + backlog
///
/// If the host's listener is unreachable (boot race, VM
/// pause, network hiccup), `connect()` fails and the dialer
/// sleeps before retrying. External events posted during a
/// disconnect window are coalesced into a single pending
/// snapshot per topic — the host doesn't care about missed
/// intermediate transitions, only the current state. On
/// reconnect, every coalesced snapshot is sent immediately
/// so the host is never stale.
final class HostEventDialer: Sendable {

    /// Vsock port matching `AgentEventListener.listenerPort`
    /// on the host.
    static let eventPort: UInt32 = 9469

    /// macOS uses the same `VMADDR_CID_HOST = 2` as Linux.
    static let hostCID: UInt32 = 2

    static let reconnectDelay: TimeInterval = 2.0

    /// Singleton so external posters (`AgentController`) can
    /// dispatch events without holding a reference. The
    /// dialer is process-wide anyway — multiple instances
    /// would fight over the vsock port.
    static let shared = HostEventDialer()

    /// Starts the dialer on a detached thread. Returns
    /// immediately; the thread lives for the agent's
    /// lifetime.
    static func start() {
        Thread.detachNewThread { shared.run() }
    }

    /// Enqueues an out-of-band event for delivery to the
    /// host on the next write opportunity. Coalesces by
    /// topic — the most recent snapshot of a topic always
    /// wins — so a rapid burst of SPICE transitions doesn't
    /// flood the stream during a reconnect window.
    static func post(_ event: GuestEvent) {
        shared.enqueue(event)
    }

    // MARK: - Private state

    /// Per-topic most-recent-snapshot. A dict rather than a
    /// queue because the host only cares about the latest
    /// state of each topic — intermediate transitions can
    /// be dropped during a reconnect window without loss of
    /// meaning.
    ///
    /// Guarded by `OSAllocatedUnfairLock`, the
    /// Swift-concurrency-idiomatic unfair-lock wrapper that
    /// owns its protected state. Preferred over `NSLock`
    /// (which can't carry `Sendable` state safely) and
    /// `DispatchQueue` (higher overhead for a
    /// sub-microsecond critical section).
    private let pending = OSAllocatedUnfairLock(
        initialState: [String: GuestEvent]()
    )

    private init() {}

    // MARK: - Posting

    private func enqueue(_ event: GuestEvent) {
        let topic = Self.topic(for: event)
        pending.withLock { state in
            state[topic] = event
        }
    }

    private func drainPending() -> [GuestEvent] {
        pending.withLock { state in
            let events = Array(state.values)
            state.removeAll(keepingCapacity: true)
            return events
        }
    }

    private static func topic(for event: GuestEvent) -> String {
        switch event {
        case .stats:         GuestEventFilter.statsTopic
        case .ports:         GuestEventFilter.portsTopic
        case .appsFrontmost: GuestEventFilter.appsFrontmostTopic
        case .spiceStatus:   GuestEventFilter.spiceStatusTopic
        }
    }

    // MARK: - Pump

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
        // `<sys/vsock.h>`. The Virtualization framework
        // brings it into user space for VM guests.
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

        // On fresh connect, flush any events posted during
        // the disconnect window so the host sees current
        // state immediately. Without this, a subscriber that
        // connects mid-session would have to wait until the
        // NEXT transition to learn the state of anything
        // other than stats.
        for event in drainPending() {
            guard let frame = try? AgentFrameCodec.encode(event, encoder: encoder) else { return }
            if !writeAll(fd: fd, data: frame) { return }
        }

        var nextStatsTick = Date()
        while true {
            // Serve any externally-posted events first so
            // responsive UI updates aren't delayed behind
            // the stats tick.
            for event in drainPending() {
                guard let frame = try? AgentFrameCodec.encode(event, encoder: encoder) else { return }
                if !writeAll(fd: fd, data: frame) { return }
            }

            // Emit the 1 Hz stats snapshot when due.
            if Date() >= nextStatsTick {
                let stats = GuestStatsResponse(
                    cpuUsage: sampleCPUUsage(),
                    memoryUsedBytes: sampleMemoryUsed(),
                    memoryTotalBytes: sampleMemoryTotal(),
                    loadAverage1m: sampleLoadAverage(),
                    processCount: sampleProcessCount(),
                    uptime: sampleUptime()
                )
                let event = GuestEvent.stats(stats)
                guard let frame = try? AgentFrameCodec.encode(event, encoder: encoder) else { return }
                if !writeAll(fd: fd, data: frame) { return }
                nextStatsTick = Date().addingTimeInterval(1.0)
            }

            // Short sleep keeps external-event latency
            // bounded to ~100 ms. Lower would burn CPU on an
            // idle VM; higher would feel laggy in the UI
            // when a SPICE state transition happens between
            // stats ticks.
            Thread.sleep(forTimeInterval: 0.1)
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
