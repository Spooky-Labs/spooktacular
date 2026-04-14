/// The Spooktacular guest agent.
///
/// `spooktacular-agent` is a daemon that runs inside a macOS guest VM and
/// exposes a rich HTTP API over a VirtIO socket (vsock). The host
/// communicates with the agent using standard HTTP/1.1 requests on
/// vsock port 9470.
///
/// ## Endpoints
///
/// The agent provides endpoints for:
/// - **Health**: `GET /health`
/// - **Exec**: `POST /api/v1/exec` -- run shell commands
/// - **Clipboard**: `GET/POST /api/v1/clipboard`
/// - **Apps**: list, launch, quit, frontmost
/// - **File system**: browse directories, upload/list files
/// - **Ports**: list listening TCP ports
///
/// See ``AgentRouter`` for the full endpoint table.
///
/// ## Installation
///
/// Copy the binary to `/usr/local/bin/spooktacular-agent` inside the guest
/// and install the companion LaunchAgent plist so macOS starts it at
/// login:
///
/// ```bash
/// sudo cp spooktacular-agent /usr/local/bin/spooktacular-agent
/// spooktacular-agent --install-agent
/// ```
///
/// For the legacy LaunchDaemon install (root, no GUI access):
///
/// ```bash
/// sudo spooktacular-agent --install-daemon
/// ```
///
/// ## Protocol Compatibility
///
/// The vsock port (9470) is shared with the host-side
/// ``VsockProvisioner/agentPort``. The wire format is now HTTP/1.1
/// instead of the previous length-prefixed binary protocol.

import Foundation
import os

// MARK: - Constants

/// The vsock port the agent listens on, matching ``VsockProvisioner/agentPort``.
private let agentPort: UInt32 = 9470

/// Path to the shared-folder token file used for agent authentication.
///
/// The file may contain one or two lines:
/// - Line 1: Full-access token (read + mutation)
/// - Line 2 (optional): Read-only token (health, list apps, list ports, etc.)
private let tokenFilePath = "/Volumes/My Shared Files/.agent-token"

/// Environment variable name for the full-access agent authentication token.
private let tokenEnvVar = "SPOOK_AGENT_TOKEN"

/// Environment variable name for the read-only agent authentication token.
private let readonlyTokenEnvVar = "SPOOK_AGENT_READONLY_TOKEN"

/// Logger for the guest agent.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "agent")

// MARK: - Token Loading

/// Tokens loaded from file or environment.
struct AgentTokens {
    /// Full-access token (read + mutation). `nil` means legacy mode.
    let fullAccess: String?
    /// Read-only token (health, list, inspect only). `nil` means no read-only token.
    let readOnly: String?
}

/// Loads agent authentication tokens from the file system or environment.
///
/// **Full-access token** is loaded from:
/// 1. Line 1 of the file at ``tokenFilePath``.
/// 2. The ``SPOOK_AGENT_TOKEN`` environment variable.
///
/// **Read-only token** is loaded from:
/// 1. Line 2 of the file at ``tokenFilePath`` (if present).
/// 2. The ``SPOOK_AGENT_READONLY_TOKEN`` environment variable.
///
/// If no full-access token is found, the agent runs in legacy mode
/// (no authentication) and a warning is logged.
///
/// - Returns: The loaded tokens.
private func loadTokens() -> AgentTokens {
    var fullAccess: String?
    var readOnly: String?

    // Try file first
    if let fileContents = try? String(contentsOfFile: tokenFilePath, encoding: .utf8) {
        let lines = fileContents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        if let first = lines.first, !first.isEmpty {
            fullAccess = first
            log.notice("Loaded full-access token from \(tokenFilePath, privacy: .public)")
        }
        if lines.count >= 2 {
            readOnly = lines[1]
            log.notice("Loaded read-only token from \(tokenFilePath, privacy: .public)")
        }
    }

    // Environment variables override file
    if let envToken = ProcessInfo.processInfo.environment[tokenEnvVar] {
        let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            fullAccess = trimmed
            log.notice("Loaded full-access token from \(tokenEnvVar, privacy: .public)")
        }
    }

    if let envReadonly = ProcessInfo.processInfo.environment[readonlyTokenEnvVar] {
        let trimmed = envReadonly.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            readOnly = trimmed
            log.notice("Loaded read-only token from \(readonlyTokenEnvVar, privacy: .public)")
        }
    }

    if fullAccess == nil {
        log.warning("No auth token found — running in legacy mode (unauthenticated). Set \(tokenEnvVar, privacy: .public) or place a token at \(tokenFilePath, privacy: .public).")
    }

    return AgentTokens(fullAccess: fullAccess, readOnly: readOnly)
}

// MARK: - Entry Point

/// Parses command-line arguments and either installs a LaunchDaemon/Agent
/// or starts the HTTP API server.
@main
enum SpookAgent {
    static func main() {
        let arguments = CommandLine.arguments

        if arguments.contains("--install-daemon") {
            LaunchDaemon.installDaemon()
            return
        }

        if arguments.contains("--install-agent") {
            LaunchDaemon.installAgent()
            return
        }

        let tokens = loadTokens()
        log.notice("spooktacular-agent starting on vsock port \(agentPort)")
        AgentHTTPServer.listen(port: agentPort, token: tokens.fullAccess, readonlyToken: tokens.readOnly)
    }
}
