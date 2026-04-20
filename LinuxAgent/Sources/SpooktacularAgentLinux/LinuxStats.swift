import Foundation

/// Guest-side metrics gatherer backed by Linux's `/proc` pseudo
/// filesystem.
///
/// Mirrors the macOS agent's `AgentStatsHandler` surface:
/// CPU-usage fraction, memory-used/total, 1-minute load average,
/// process count, uptime. Same JSON shape goes on the wire so the
/// host's `GuestStatsResponse` decoder Just Works for either
/// guest OS.
///
/// Read from:
///   - `/proc/stat`      — CPU ticks (user / nice / system / idle / iowait).
///   - `/proc/meminfo`   — total + available memory in kB.
///   - `/proc/loadavg`   — 1-minute load average.
///   - `/proc/uptime`    — seconds since boot.
///
/// Process count is the number of numeric-named entries under
/// `/proc` — the canonical way to count live PIDs on Linux
/// without shelling out to `ps`.
struct LinuxStatsSampler {

    /// Last cumulative CPU-tick sample. `nil` until the first
    /// read — matches the macOS agent's "first sample returns nil
    /// usage because the delta needs two observations" contract.
    private var previous: CPUSample?

    struct CPUSample {
        let user: UInt64
        let nice: UInt64
        let system: UInt64
        let idle: UInt64
        let iowait: UInt64
        var total: UInt64 { user &+ nice &+ system &+ idle &+ iowait }
    }

    struct StatsFrame: Encodable {
        // Field names match `GuestStatsResponse` on the host so
        // the on-wire JSON decodes identically to what the macOS
        // agent produces.
        let cpuUsage: Double?
        let memoryUsedBytes: UInt64
        let memoryTotalBytes: UInt64
        let loadAverage1m: Double
        let processCount: Int
        let uptime: TimeInterval
    }

    mutating func sample() -> StatsFrame {
        let cpu = Self.readCPUTicks()
        let usage: Double?
        if let prev = previous, let now = cpu {
            let totalDelta = now.total &- prev.total
            if totalDelta > 0 {
                let idleDelta = (now.idle &+ now.iowait) &- (prev.idle &+ prev.iowait)
                let busyDelta = totalDelta &- idleDelta
                usage = max(0, min(1.0, Double(busyDelta) / Double(totalDelta)))
            } else {
                usage = 0
            }
        } else {
            usage = nil
        }
        if let cpu { previous = cpu }

        let (memUsed, memTotal) = Self.readMemory()
        return StatsFrame(
            cpuUsage: usage,
            memoryUsedBytes: memUsed,
            memoryTotalBytes: memTotal,
            loadAverage1m: Self.readLoadAverage(),
            processCount: Self.countProcesses(),
            uptime: Self.readUptime()
        )
    }

    // MARK: - /proc readers

    private static func readCPUTicks() -> CPUSample? {
        guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("cpu ") else { continue }
            // `cpu  user nice system idle iowait irq softirq steal guest guest_nice`
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 6 else { return nil }
            let user = UInt64(fields[1]) ?? 0
            let nice = UInt64(fields[2]) ?? 0
            let system = UInt64(fields[3]) ?? 0
            let idle = UInt64(fields[4]) ?? 0
            let iowait = UInt64(fields[5]) ?? 0
            return CPUSample(user: user, nice: nice, system: system, idle: idle, iowait: iowait)
        }
        return nil
    }

    /// Returns (used, total) in bytes. "Used" follows the same
    /// definition the host UI expects — `total - available` —
    /// which is the modern Linux equivalent of macOS's "active +
    /// wired + compressed" (both exclude file cache pages that
    /// the kernel will reclaim on demand).
    private static func readMemory() -> (used: UInt64, total: UInt64) {
        guard let text = try? String(contentsOfFile: "/proc/meminfo", encoding: .utf8) else {
            return (0, 0)
        }
        var total: UInt64 = 0
        var available: UInt64 = 0
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2 else { continue }
            let key = fields[0]
            let valueKiB = UInt64(fields[1]) ?? 0
            if key == "MemTotal:" { total = valueKiB * 1024 }
            if key == "MemAvailable:" { available = valueKiB * 1024 }
            if total > 0, available > 0 { break }
        }
        let used = total > available ? total - available : 0
        return (used, total)
    }

    private static func readLoadAverage() -> Double {
        guard let text = try? String(contentsOfFile: "/proc/loadavg", encoding: .utf8) else {
            return 0
        }
        // `0.05 0.03 0.00 1/123 456`
        let first = text.split(separator: " ").first ?? ""
        return Double(first) ?? 0
    }

    private static func readUptime() -> TimeInterval {
        guard let text = try? String(contentsOfFile: "/proc/uptime", encoding: .utf8) else {
            return 0
        }
        let first = text.split(separator: " ").first ?? ""
        return TimeInterval(first) ?? 0
    }

    private static func countProcesses() -> Int {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return 0
        }
        return entries.reduce(0) { $0 + (UInt($1) == nil ? 0 : 1) }
    }
}
