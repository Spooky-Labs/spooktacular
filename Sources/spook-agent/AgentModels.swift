/// Codable request and response types for the spook-agent HTTP API.
///
/// These models define the JSON wire format for every endpoint the
/// agent exposes. All types are `Codable` and `Sendable` so they
/// can be safely encoded/decoded and passed across concurrency
/// boundaries.
///
/// ## Conventions
///
/// - Request types end in `Request` and match the expected POST body.
/// - Response types end in `Response` or describe the resource.
/// - ``FilePayload/data`` is Base64-encoded to safely embed binary
///   content in JSON.

import Foundation

// MARK: - Exec

/// A request to execute a shell command inside the guest.
///
/// The ``command`` string is passed to `/bin/bash -c`, so it may
/// contain pipes, redirects, and other shell constructs.
struct ExecRequest: Codable, Sendable {
    /// The shell command to execute.
    let command: String
    /// Optional timeout in seconds. Defaults to 30 if omitted.
    let timeout: Int?
}

/// The result of a shell command execution.
struct ExecResponse: Codable, Sendable {
    /// The process exit code (0 = success).
    let exitCode: Int32
    /// Standard output captured from the process.
    let stdout: String
    /// Standard error captured from the process.
    let stderr: String
}

// MARK: - Clipboard

/// Clipboard content for `GET` and `POST /api/v1/clipboard`.
struct ClipboardContent: Codable, Sendable {
    /// The plain-text clipboard content.
    let text: String
}

// MARK: - Apps

/// Information about a running application.
struct AppInfo: Codable, Sendable {
    /// The localized application name.
    let name: String
    /// The CFBundleIdentifier (e.g., `"com.apple.Safari"`).
    let bundleID: String
    /// Whether this application is the frontmost (active) app.
    let isActive: Bool
    /// The UNIX process identifier.
    let pid: Int32
}

/// A request to launch or quit an application by bundle identifier.
struct AppRequest: Codable, Sendable {
    /// The bundle identifier of the application.
    let bundleID: String
}

// MARK: - File System

/// A single directory entry returned by `GET /api/v1/fs`.
struct FSEntry: Codable, Sendable {
    /// The file or directory name (not a full path).
    let name: String
    /// `true` if this entry is a directory.
    let isDirectory: Bool
    /// The file size in bytes (0 for directories).
    let size: UInt64
}

// MARK: - File Transfer

/// A file payload for upload/download, with Base64-encoded data.
struct FilePayload: Codable, Sendable {
    /// The file name (without directory components).
    let name: String
    /// The file contents, Base64-encoded.
    let data: String
}

// MARK: - Ports

/// Information about a listening TCP port.
struct PortInfo: Codable, Sendable {
    /// The TCP port number.
    let port: UInt16
    /// The process ID that owns the socket.
    let pid: Int32
    /// The name of the process.
    let processName: String
}

// MARK: - Health

/// The health-check response returned by `GET /health`.
struct HealthResponse: Codable, Sendable {
    /// Always `"ok"` when the agent is running.
    let status: String
    /// The agent version string.
    let version: String
    /// Seconds since the agent process started.
    let uptime: TimeInterval
}
