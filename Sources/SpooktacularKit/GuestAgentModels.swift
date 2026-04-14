import Foundation

// MARK: - Guest Agent Response Models

/// Health status reported by the guest agent.
///
/// Returned by `GET /health`. Use this to verify the agent is
/// running and to check version compatibility.
public struct GuestHealthResponse: Codable, Sendable {
    /// Always `"ok"` when the agent is healthy.
    public let status: String
    /// The agent's semantic version string.
    public let version: String
    /// Seconds since the agent process started.
    public let uptime: TimeInterval
}

/// The result of executing a shell command inside the guest.
///
/// Returned by `POST /api/v1/exec`. The ``exitCode`` follows
/// standard UNIX conventions: 0 means success, non-zero means
/// failure.
public struct GuestExecResponse: Codable, Sendable {
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
public struct GuestAppInfo: Codable, Sendable {
    /// The localized application name (e.g., "Safari").
    public let name: String
    /// The CFBundleIdentifier (e.g., `"com.apple.Safari"`).
    public let bundleID: String
    /// Whether this application is the frontmost (active) app.
    public let isActive: Bool
    /// The UNIX process identifier.
    public let pid: Int32
}

/// A file-system directory entry inside the guest.
///
/// Returned by `GET /api/v1/fs?path=...` as an array of entries.
public struct GuestFSEntry: Codable, Sendable {
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
public struct GuestFileInfo: Codable, Sendable {
    /// The file name.
    public let name: String
    /// The file contents, Base64-encoded.
    public let data: String
}

/// Information about a listening TCP port inside the guest.
///
/// Returned by `GET /api/v1/ports` as an array.
public struct GuestPortInfo: Codable, Sendable {
    /// The TCP port number.
    public let port: UInt16
    /// The process ID that owns the socket.
    public let pid: Int32
    /// The name of the process.
    public let processName: String
}

// MARK: - Internal Request Bodies

/// JSON body for `POST /api/v1/exec`.
struct GuestExecRequest: Codable, Sendable {
    let command: String
    let timeout: Int?
}

/// JSON body for `POST /api/v1/clipboard`.
struct GuestClipboardContent: Codable, Sendable {
    let text: String
}

/// JSON body for `POST /api/v1/apps/launch` and
/// `DELETE /api/v1/apps`.
struct GuestAppRequest: Codable, Sendable {
    let bundleID: String
}

/// JSON body for `POST /api/v1/files`.
struct GuestFilePayload: Codable, Sendable {
    let name: String
    let data: String
}
