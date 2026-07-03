import Foundation

// MARK: - Guest Agent Response Models

/// Rolling system metrics reported by the guest agent.
///
/// Returned by `GET /api/v1/stats`. Sampled on demand — the
/// agent computes a CPU-usage delta against the last sample it
/// served, so two requests ~1s apart give a meaningful rate.
///
/// ## Clean-architecture placement
///
/// This is a shared DTO: the guest-side sampler fills it in
/// from `host_statistics64` / `sysctl`, and the host decodes it.
/// Keeping it in `SpooktacularCore` (Foundation-only, zero
/// framework dependencies) means both sides compile without
/// pulling each other's concerns in.
public struct GuestStatsResponse: Codable, Sendable, Equatable {
    /// CPU usage as a fraction in `0.0 … 1.0` (0 = idle, 1 =
    /// every core pinned). `nil` on the first sample since a
    /// delta requires two.
    public let cpuUsage: Double?

    /// Bytes of physical memory currently in use by the guest
    /// (active + wired + compressed), excluding cached file
    /// pages.
    public let memoryUsedBytes: UInt64

    /// Total physical memory installed in the guest, in bytes.
    public let memoryTotalBytes: UInt64

    /// 1-minute load average.
    public let loadAverage1m: Double

    /// Number of processes currently running inside the guest
    /// (excluding kernel threads).
    public let processCount: Int

    /// Seconds since the guest booted.
    public let uptime: TimeInterval

    /// Cumulative bytes read from disk since the VM started.
    /// `nil` when the source is pre-v2 (guest agent running
    /// an older schema). Host-side samples via `libproc`'s
    /// `ri_diskio_bytesread` always fill this in.
    public let diskBytesRead: UInt64?

    /// Cumulative bytes written to disk since the VM started.
    /// `nil` when the source is pre-v2. Host-side samples
    /// via `libproc`'s `ri_diskio_byteswritten` always fill
    /// this in.
    public let diskBytesWritten: UInt64?

    /// Cumulative energy used by the VM's backing process,
    /// in nanojoules. `nil` outside host-observed samples —
    /// guests can't measure their own host-side energy
    /// footprint. Sourced from `libproc`'s `ri_energy`.
    public let energyNanoJoules: UInt64?

    /// Cumulative page-ins (on-demand faults pulling pages
    /// back into resident RAM) since the VM started. A
    /// high-growth rate here is the host-side signal of
    /// memory pressure / swapping activity inside the VM.
    /// `nil` when the source doesn't provide it. Host-side
    /// samples read `ri_pageins`.
    public let pageIns: UInt64?

    public init(
        cpuUsage: Double?,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        loadAverage1m: Double,
        processCount: Int,
        uptime: TimeInterval,
        diskBytesRead: UInt64? = nil,
        diskBytesWritten: UInt64? = nil,
        energyNanoJoules: UInt64? = nil,
        pageIns: UInt64? = nil
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.loadAverage1m = loadAverage1m
        self.processCount = processCount
        self.uptime = uptime
        self.diskBytesRead = diskBytesRead
        self.diskBytesWritten = diskBytesWritten
        self.energyNanoJoules = energyNanoJoules
        self.pageIns = pageIns
    }

    /// Convenience: memory usage as a fraction in `0.0 … 1.0`.
    public var memoryUsageFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}

/// Information about a running application inside the guest.
///
/// Reported as part of the guest event stream (as an array) and
/// as the single frontmost application, when available.
public struct GuestAppInfo: Codable, Sendable, Equatable {
    /// The localized application name (e.g., "Safari").
    public let name: String
    /// The CFBundleIdentifier (e.g., `"com.apple.Safari"`).
    public let bundleID: String
    /// Whether this application is the frontmost (active) app.
    public let isActive: Bool
    /// The UNIX process identifier.
    public let pid: Int32

    public init(name: String, bundleID: String, isActive: Bool, pid: Int32) {
        self.name = name
        self.bundleID = bundleID
        self.isActive = isActive
        self.pid = pid
    }
}

/// Information about a listening TCP port inside the guest.
///
/// Reported as part of the guest event stream, as an array.
public struct GuestPortInfo: Codable, Sendable, Equatable {
    /// The TCP port number.
    public let port: UInt16
    /// The process ID that owns the socket.
    public let pid: Int32
    /// The name of the process.
    public let processName: String

    public init(port: UInt16, pid: Int32, processName: String) {
        self.port = port
        self.pid = pid
        self.processName = processName
    }
}
