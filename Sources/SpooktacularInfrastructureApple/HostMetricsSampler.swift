import Foundation
import Darwin
import SpooktacularCore
import os

/// Samples a running VM's resource usage from the host side,
/// without needing an in-guest agent.
///
/// ## Why this exists
///
/// `Virtualization.framework` spawns a per-VM XPC helper
/// (`com.apple.Virtualization.VirtualMachine`) as a child
/// process of whoever calls `VZVirtualMachine.start`. That
/// child process hosts the VM's vCPUs and emulated devices,
/// so the kernel accounts its CPU time, resident memory,
/// page faults, and device I/O against the child — and Apple
/// exposes those counters to the parent via `libproc`'s
/// `proc_pid_rusage(_:_:_:)` API, no entitlement required.
///
/// That's the same data path Activity Monitor, `top`, and
/// `powermetrics` read from for virtualization workloads,
/// and it's enough to drive a "CPU % + memory used over
/// time" chart in the GUI. No guest agent, no LaunchDaemon,
/// no admin prompt — metrics start flowing the moment the
/// VM's first vCPU begins executing.
///
/// ## What it does NOT cover
///
/// Host-observed metrics are coarse-grained: they describe
/// how much the *virtualization runtime* is consuming, not
/// what's happening *inside* the guest. Data that inherently
/// requires the guest's kernel — load average, per-process
/// CPU trees, open TCP ports, frontmost-app tracking, disk
/// free space per guest filesystem — still needs an
/// in-guest agent. The agent path (`AgentEventListener`)
/// remains as an opt-in for those richer workloads.
///
/// ## Attribution to a specific VM
///
/// `Virtualization.framework` doesn't expose the XPC child's
/// PID on `VZVirtualMachine`, and `com.apple.Virtualization.
/// VirtualMachine` doesn't identify itself via any queryable
/// API. We attribute PIDs to VMs by *diffing* our child-
/// process list across the VM start boundary:
///
/// 1. `captureChildren(excluding:)` before `vm.start()` —
///    snapshot the current child-PID set.
/// 2. `vm.start()` spawns new XPC workers.
/// 3. `captureChildren(excluding: snapshot)` after start —
///    the new PIDs belong to this VM.
///
/// Subsequent VM starts, clones, snapshots, etc. all rely on
/// the same caller-supplied baseline set.
///
/// ## Thread safety
///
/// `HostMetricsSampler` is an `actor`; `sample()` is the
/// only externally-callable method and it's async. The
/// internal PID set is never mutated after init — the
/// sampler is bound to one VM for its whole lifetime and
/// discarded on `stopVM`.
public actor HostMetricsSampler {

    // MARK: - Types

    private struct CPUBaseline {
        /// Wall-clock timestamp of the previous `sample()`
        /// call, used to compute CPU % as delta-cpu-time /
        /// delta-wall-time over the interval.
        let wallClock: Date
        /// Total user + system CPU time (in nanoseconds)
        /// across every XPC helper PID at the previous
        /// sample. Per-PID summation lets us survive
        /// XPC-worker churn (macOS occasionally relaunches
        /// a crashed worker) without losing the delta.
        let cpuNanos: UInt64
    }

    // MARK: - State

    /// VM bundle name, used for log attribution.
    private let vmName: String

    /// Virtual CPUs in the VM's spec. Used as the divisor
    /// when converting "sum of vCPU runtime" into a "% of
    /// total compute allocated to this VM" — so a VM with 4
    /// vCPUs all pinned at 100% reports as 1.0 (fully
    /// saturated), not 4.0.
    private let vCPUs: Int

    /// Memory ceiling in bytes from the VM's spec. Reported
    /// as `memoryTotalBytes` in the emitted snapshot so the
    /// GUI chart's percent axis has a denominator without
    /// having to round-trip the guest agent.
    private let memoryTotalBytes: UInt64

    /// Timestamp of `init` — used as the VM uptime anchor
    /// (close enough; a handful of ms of XPC-spawn latency
    /// isn't visible on a minutes-scale chart).
    private let startedAt: Date

    /// PIDs of `com.apple.Virtualization.VirtualMachine`
    /// child processes that belong to *this* VM.
    private let xpcPIDs: [pid_t]

    /// Previous-sample cache for CPU-delta math.
    private var cpuBaseline: CPUBaseline?

    private static let log = Logger(
        subsystem: "com.spooktacular.infra",
        category: "host-metrics-sampler"
    )

    // MARK: - Init

    /// - Parameters:
    ///   - vmName: For log attribution only.
    ///   - vCPUs: From `VirtualMachineSpecification.cpuCount`.
    ///   - memoryTotalBytes: From `VirtualMachineSpecification.
    ///     memorySizeInBytes`.
    ///   - pidsBeforeStart: The set of VZ XPC child PIDs
    ///     captured *immediately before* `vm.start()`. Any
    ///     `com.apple.Virtualization.VirtualMachine` PIDs
    ///     that appear after the start call but weren't in
    ///     this set are attributed to this VM. Callers get
    ///     the baseline via ``HostMetricsSampler/
    ///     captureVirtualizationPIDs()``.
    public init(
        vmName: String,
        vCPUs: Int,
        memoryTotalBytes: UInt64,
        pidsBeforeStart: Set<pid_t>
    ) {
        self.vmName = vmName
        self.vCPUs = vCPUs
        self.memoryTotalBytes = memoryTotalBytes
        self.startedAt = Date()

        let after = Self.captureVirtualizationPIDs()
        let newPIDs = after.subtracting(pidsBeforeStart).sorted()
        self.xpcPIDs = newPIDs

        Self.log.notice(
            "Attached sampler to '\(vmName, privacy: .public)': \(newPIDs.count, privacy: .public) XPC PID(s) \(newPIDs.description, privacy: .public)"
        )
    }

    // MARK: - Public API

    /// Takes one sample and returns a snapshot shaped exactly
    /// like the guest-agent metrics frames so the existing
    /// publisher path (``VMStreamingServer``, the sidebar
    /// chart) can consume it without branching.
    ///
    /// First call seeds the CPU-delta baseline and returns a
    /// snapshot with `cpuUsage = 0`. Each subsequent call
    /// reports the CPU % used since the previous call.
    public func sample() -> VMMetricsSnapshot {
        let now = Date()
        var totalCPUNanos: UInt64 = 0
        var totalResidentBytes: UInt64 = 0
        var totalDiskBytesRead: UInt64 = 0
        var totalDiskBytesWritten: UInt64 = 0
        var totalEnergyNanoJoules: UInt64 = 0
        var totalPageIns: UInt64 = 0

        for pid in xpcPIDs {
            // CPU time: shell out to `ps -o time=`.
            //
            // Why not use one of the `libproc` CPU paths?
            // `proc_pid_rusage`, `PROC_PIDTASKINFO`, and even
            // sysctl `KERN_PROC` all under-report by 30-100×
            // for VM workloads — empirically (2026-04-21)
            // `ps` reports 39% CPU on a VM XPC worker while
            // every `libproc` path reports ~1%. Apple's
            // `top(1)` and `ps(1)` read the process's real
            // CPU time (which includes hypervisor-mode guest
            // execution) through paths that require either
            // `task_for_pid` (entitlement-gated) or BSD
            // internals not exposed to Swift.
            //
            // `ps -o time=` gives the cumulative CPU time in
            // `[DD-]HH:MM:SS.ms` format, accurate to ±10ms,
            // includes hypervisor-mode time. We parse + delta
            // it just like we delta disk bytes.
            totalCPUNanos = totalCPUNanos &+ Self.cumulativeCPUNanos(pid: pid)

            // rusage_info_v6 is still the source for disk I/O,
            // energy, page-ins, and resident memory — those
            // counters aren't exposed through `ps`.
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
                }
            }
            guard rc == 0 else {
                // PID gone (worker crashed, VM stopped between
                // sampler init and now). Skip silently — the
                // outer publisher will stop us on VM stop; any
                // transient gap just shows as a flatline on
                // the chart.
                continue
            }
            // `ri_resident_size` vs `ri_phys_footprint` for
            // a VM workload:
            //
            //   - `phys_footprint` counts every page the
            //     backing XPC worker has *ever committed*,
            //     including compressed + swapped-out pages.
            //     For a VM, almost every allocated byte gets
            //     touched during boot, so this pins at ≈
            //     full memory allocation for the VM's
            //     lifetime. Visually flat at 100% — no
            //     information value in a chart.
            //
            //   - `resident_size` is just pages currently in
            //     physical RAM on the host. Macos's kernel
            //     compresses / evicts VM pages that haven't
            //     been touched recently, so this fluctuates
            //     with guest activity and produces a
            //     chart shape that tracks real workload.
            //
            // The trade-off: `resident_size` under-reports
            // "how much RAM this VM actually costs me"
            // because compressed pages are still charged to
            // the process. For the sidebar chart where the
            // goal is "show the guest doing work", the
            // fluctuating signal is what the user wants.
            // External UDS consumers that want the ceiling
            // can derive it from `memoryTotalBytes`.
            totalResidentBytes = totalResidentBytes &+ info.ri_resident_size
            totalDiskBytesRead = totalDiskBytesRead &+ info.ri_diskio_bytesread
            totalDiskBytesWritten = totalDiskBytesWritten &+ info.ri_diskio_byteswritten
            // `ri_billed_energy` is the cumulative nJ the
            // scheduler has attributed to this process — the
            // same source `powermetrics` reads from. There's
            // also `ri_serviced_energy` (energy consumed on
            // behalf of OTHER processes); for "how much power
            // is the VM burning", billed is the right one.
            totalEnergyNanoJoules = totalEnergyNanoJoules &+ info.ri_billed_energy
            totalPageIns = totalPageIns &+ UInt64(info.ri_pageins)
        }

        // First call has no prior baseline to compute a delta
        // from; emit `nil` so the chart renders a gap rather
        // than a misleading 0%. Every subsequent call returns
        // a concrete fraction in [0, 1].
        let cpuUsage: Double?
        if let prev = cpuBaseline {
            let wallDelta = now.timeIntervalSince(prev.wallClock)
            let cpuDelta = Int64(totalCPUNanos) - Int64(prev.cpuNanos)
            if wallDelta > 0 && cpuDelta >= 0 {
                // ns of CPU time used / ns of wall time * vCPUs
                // yields a fraction in [0, 1] where 1 means
                // every vCPU was saturated over the interval.
                let divisor = wallDelta * 1_000_000_000 * Double(max(1, vCPUs))
                cpuUsage = min(1.0, Double(cpuDelta) / divisor)
            } else {
                cpuUsage = 0
            }
        } else {
            cpuUsage = nil
        }
        cpuBaseline = CPUBaseline(wallClock: now, cpuNanos: totalCPUNanos)

        return VMMetricsSnapshot(
            at: now,
            cpuUsage: cpuUsage,
            memoryUsedBytes: totalResidentBytes,
            memoryTotalBytes: memoryTotalBytes,
            // `loadAverage1m` and `processCount` are
            // in-guest-only metrics; 0 reads as "—" in the
            // chart. The in-guest agent path fills these in
            // when (opt-in) installed.
            loadAverage1m: 0,
            processCount: 0,
            uptime: now.timeIntervalSince(startedAt),
            diskBytesRead: totalDiskBytesRead,
            diskBytesWritten: totalDiskBytesWritten,
            energyNanoJoules: totalEnergyNanoJoules,
            pageIns: totalPageIns
        )
    }

    // MARK: - PID Discovery

    /// Reads `ps -p <pid> -o time=` and returns the cumulative
    /// CPU time as nanoseconds. Format is `[DD-]HH:MM:SS.ff`.
    ///
    /// `ps` is the only tool we can invoke from a sandbox-free
    /// non-root process that actually counts hypervisor-mode
    /// guest execution time — `libproc`'s CPU counters
    /// (`ri_user_time`, `pti_total_user`, `KERN_PROC p_uticks`)
    /// all under-report VM workloads by 30-100×. Spawning `ps`
    /// at 1 Hz is ~5ms CPU per sample on M-class silicon,
    /// negligible compared to the VM's own draw.
    ///
    /// Returns `0` if `ps` fails (process gone, format
    /// unexpected, etc.) — the caller sees a zero-delta for
    /// that sample, which renders as a chart gap rather than
    /// a spike.
    private static func cumulativeCPUNanos(pid: pid_t) -> UInt64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "time="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return 0
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return 0 }
        let raw = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: raw, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return 0 }
        return parseCPUTime(text) ?? 0
    }

    /// Parses a BSD `ps -o time` string → nanoseconds.
    ///
    /// BSD `ps` emits CPU time in three formats depending on
    /// magnitude:
    ///   - `MM:SS.ff` for totals under an hour (`5:24.50`)
    ///   - `HH:MM:SS.ff` for one hour up to a day
    ///   - `DD-HH:MM:SS.ff` for totals spanning days
    ///
    /// Earlier revisions required three colon-separated parts
    /// and silently rejected the common `MM:SS.ff` form,
    /// producing a persistent zero reading for any VM with
    /// less than an hour of CPU accumulated — defeating the
    /// whole purpose of the `ps` fallback.
    ///
    /// Exposed `internal` for unit tests.
    static func parseCPUTime(_ input: String) -> UInt64? {
        var remainder = input[...]
        var days: Int = 0
        if let dashIdx = remainder.firstIndex(of: "-"),
           remainder.firstIndex(of: ":").map({ dashIdx < $0 }) == true {
            days = Int(remainder[..<dashIdx]) ?? 0
            remainder = remainder[remainder.index(after: dashIdx)...]
        }
        let parts = remainder.split(separator: ":")
        let hours: Int
        let minutes: Int
        let secondsStr: Substring
        switch parts.count {
        case 2:
            // `MM:SS.ff` — the common sub-hour case.
            hours = 0
            minutes = Int(parts[0]) ?? 0
            secondsStr = parts[1]
        case 3:
            // `HH:MM:SS.ff` for >= 1 hour CPU totals.
            hours = Int(parts[0]) ?? 0
            minutes = Int(parts[1]) ?? 0
            secondsStr = parts[2]
        default:
            return nil
        }
        let seconds: Double = Double(secondsStr) ?? 0
        let total = Double(days) * 86400
                  + Double(hours) * 3600
                  + Double(minutes) * 60
                  + seconds
        return UInt64(total * 1_000_000_000)
    }

    /// Returns the current set of PIDs whose executable path
    /// matches the VM backing XPC helper
    /// (`com.apple.Virtualization.VirtualMachine.xpc`).
    ///
    /// ### Why we have to scan all PIDs
    ///
    /// Apple's Virtualization framework spawns the VM's
    /// backing worker via `launchd` as an XPC service, so
    /// `launchd` (PID 1) is the process's parent — *not* the
    /// host app that called `VZVirtualMachine.start`. That
    /// means `proc_listpids(PROC_PPID_ONLY, getpid(), …)`
    /// returns zero matches. The only way to find the worker
    /// is to enumerate every PID on the system (via
    /// `PROC_ALL_PIDS`) and filter by executable path.
    ///
    /// Callers snapshot this *before* `VZVirtualMachine.
    /// start()`, pass the snapshot to ``init``, and the
    /// sampler diff-attributes any new PIDs to the VM. The
    /// full-system enumeration is cheap (~a few hundred
    /// PIDs, one syscall) and only runs twice per VM start.
    public static func captureVirtualizationPIDs() -> Set<pid_t> {
        // `proc_listpids(PROC_ALL_PIDS, 0, nil, 0)` returns
        // the total byte count the caller needs to allocate.
        let byteCap = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCap > 0 else { return [] }

        // Oversize by 64 slots to cover races where a new
        // process appears between the size query and the
        // fetch call.
        let capacity = Int(byteCap) / MemoryLayout<pid_t>.stride + 64
        var buffer = [pid_t](repeating: 0, count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                ptr.baseAddress,
                Int32(ptr.count * MemoryLayout<pid_t>.stride)
            )
        }
        guard written > 0 else { return [] }

        let count = Int(written) / MemoryLayout<pid_t>.stride
        var result: Set<pid_t> = []
        // `PROC_PIDPATHINFO_MAXSIZE` is defined as
        // `4 * MAXPATHLEN` in `<sys/proc_info.h>` but Swift
        // can't import the macro directly. 4096 matches
        // exactly — Darwin's MAXPATHLEN has been 1024 since
        // forever.
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        for pid in buffer.prefix(count) where pid > 0 {
            let n = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard n > 0 else { continue }
            let path = String(cString: pathBuffer)
            // Match the canonical VM backing path exactly.
            // We deliberately DON'T match the other VZ
            // helpers (EventTap, AppleVirtualPlatformIdentity,
            // …) because only `VirtualMachine.xpc` carries
            // the vCPU runtime and memory footprint. The
            // others use trivial CPU and would add noise.
            if path.hasSuffix("/com.apple.Virtualization.VirtualMachine") {
                result.insert(pid)
            }
        }
        return result
    }
}
