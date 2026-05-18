import Foundation

// MARK: - Guest Agent Response Models

/// Health status reported by the guest agent.
///
/// Returned by `GET /health`. Use this to verify the agent is
/// running and to check version compatibility.
public struct GuestHealthResponse: Codable, Sendable, Equatable {
    /// Always `"ok"` when the agent is healthy.
    public let status: String
    /// The agent's semantic version string.
    public let version: String
    /// Seconds since the agent process started.
    public let uptime: TimeInterval
}

/// Rolling system metrics reported by the guest agent.
///
/// Returned by `GET /api/v1/stats`. Sampled on demand — the
/// agent computes a CPU-usage delta against the last sample it
/// served, so two requests ~1s apart give a meaningful rate.
///
/// ## Clean-architecture placement
///
/// This is a shared DTO: the guest `AgentRouter` fills it in
/// from `host_statistics64` / `sysctl`, and the host
/// `GuestAgentClient` decodes it. Keeping it in `SpooktacularCore`
/// (Foundation-only, zero framework dependencies) means both
/// sides compile without pulling each other's concerns in.
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

    public init(
        cpuUsage: Double?,
        memoryUsedBytes: UInt64,
        memoryTotalBytes: UInt64,
        loadAverage1m: Double,
        processCount: Int,
        uptime: TimeInterval
    ) {
        self.cpuUsage = cpuUsage
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.loadAverage1m = loadAverage1m
        self.processCount = processCount
        self.uptime = uptime
    }

    /// Convenience: memory usage as a fraction in `0.0 … 1.0`.
    public var memoryUsageFraction: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}

/// The result of executing a shell command inside the guest.
///
/// Returned by `POST /api/v1/exec`. The ``exitCode`` follows
/// standard UNIX conventions: 0 means success, non-zero means
/// failure.
public struct GuestExecResponse: Codable, Sendable, Equatable {
    /// The process exit code (0 = success).
    public let exitCode: Int32
    /// Standard output captured from the process.
    public let stdout: String
    /// Standard error captured from the process.
    public let stderr: String
}

/// Information about a running application inside the guest.
///
/// Returned by `GET /api/v1/apps` (as an array) and
/// `GET /api/v1/apps/frontmost` (single, optional).
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

/// A file-system directory entry inside the guest.
///
/// Returned by `GET /api/v1/fs?path=...` as an array of entries.
public struct GuestFSEntry: Codable, Sendable, Equatable {
    /// The file or directory name (not a full path).
    public let name: String
    /// `true` if this entry is a directory.
    public let isDirectory: Bool
    /// The file size in bytes (0 for directories).
    public let size: UInt64
}

/// Metadata about a file available for download from the guest.
///
/// Returned by `GET /api/v1/files` as an array.
public struct GuestFileInfo: Codable, Sendable, Equatable {
    /// The file name.
    public let name: String
    /// The file contents, Base64-encoded.
    public let data: String
}

/// Information about a listening TCP port inside the guest.
///
/// Returned by `GET /api/v1/ports` as an array.
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

// MARK: - Internal Request Bodies

/// JSON body for `POST /api/v1/exec`.
public struct GuestExecRequest: Codable, Sendable, Equatable {
    public let command: String
    public let timeout: Int?

    public init(command: String, timeout: Int?) {
        self.command = command
        self.timeout = timeout
    }
}

/// JSON body for `POST /api/v1/clipboard`.
public struct GuestClipboardContent: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

/// JSON body for `POST /api/v1/apps/launch` and
/// `POST /api/v1/apps/quit`.
public struct GuestAppRequest: Codable, Sendable, Equatable {
    public let bundleID: String

    public init(bundleID: String) {
        self.bundleID = bundleID
    }
}

/// JSON body for `POST /api/v1/files`.
public struct GuestFilePayload: Codable, Sendable, Equatable {
    public let name: String
    public let data: String

    public init(name: String, data: String) {
        self.name = name
        self.data = data
    }
}
