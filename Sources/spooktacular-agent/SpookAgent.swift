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
/// The file may contain up to three lines:
/// - Line 1: Admin (break-glass) token — full access including exec
/// - Line 2 (optional): Runner token — mutation except exec
/// - Line 3 (optional): Read-only token (health, list apps, list ports, etc.)
private let tokenFilePath = "/Volumes/My Shared Files/.agent-token"

/// Environment variable name for the admin (break-glass) agent authentication token.
private let tokenEnvVar = "SPOOK_AGENT_TOKEN"

/// Environment variable name for the runner agent authentication token.
private let runnerTokenEnvVar = "SPOOK_AGENT_RUNNER_TOKEN"

/// Environment variable name for the read-only agent authentication token.
private let readonlyTokenEnvVar = "SPOOK_AGENT_READONLY_TOKEN"

/// Logger for the guest agent.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "agent")

// MARK: - Token Loading

/// Tokens loaded from file or environment.
struct AgentTokens {
    /// Admin (break-glass) token — grants access to all endpoints including exec.
    /// `nil` means legacy mode (no authentication).
    let admin: String?
    /// Runner token — grants mutation access (launch/quit apps, clipboard, files)
    /// but NOT exec. `nil` means no runner token configured.
    let runner: String?
    /// Read-only token — grants access to GET endpoints only.
    /// `nil` means no read-only token configured.
    let readOnly: String?
}

/// Loads agent authentication tokens from the file system or environment.
///
/// **Admin (break-glass) token** is loaded from:
/// 1. Line 1 of the file at ``tokenFilePath``.
/// 2. The ``SPOOK_AGENT_TOKEN`` environment variable (overrides file).
///
/// **Runner token** is loaded from:
/// 1. Line 2 of the file at ``tokenFilePath`` (if present).
/// 2. The ``SPOOK_AGENT_RUNNER_TOKEN`` environment variable (overrides file).
///
/// **Read-only token** is loaded from:
/// 1. Line 3 of the file at ``tokenFilePath`` (if present).
/// 2. The ``SPOOK_AGENT_READONLY_TOKEN`` environment variable (overrides file).
///
/// If no admin token is found, the agent runs in legacy mode
/// (no authentication) and a warning is logged.
///
/// - Returns: The loaded tokens.
private func loadTokens() -> AgentTokens {
    var admin: String?
    var runner: String?
    var readOnly: String?

    // Try file first
    if let fileContents = try? String(contentsOfFile: tokenFilePath, encoding: .utf8) {
        let lines = fileContents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        if let first = lines.first, !first.isEmpty {
            admin = first
            log.notice("Loaded admin token from \(tokenFilePath, privacy: .public)")
        }
        if lines.count >= 2 {
            runner = lines[1]
            log.notice("Loaded runner token from \(tokenFilePath, privacy: .public)")
        }
        if lines.count >= 3 {
            readOnly = lines[2]
            log.notice("Loaded read-only token from \(tokenFilePath, privacy: .public)")
        }
    }

    // Environment variables override file
    if let envToken = ProcessInfo.processInfo.environment[tokenEnvVar] {
        let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            admin = trimmed
            log.notice("Loaded admin token from \(tokenEnvVar, privacy: .public)")
        }
    }

    if let envRunner = ProcessInfo.processInfo.environment[runnerTokenEnvVar] {
        let trimmed = envRunner.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            runner = trimmed
            log.notice("Loaded runner token from \(runnerTokenEnvVar, privacy: .public)")
        }
    }

    if let envReadonly = ProcessInfo.processInfo.environment[readonlyTokenEnvVar] {
        let trimmed = envReadonly.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            readOnly = trimmed
            log.notice("Loaded read-only token from \(readonlyTokenEnvVar, privacy: .public)")
        }
    }

    if admin == nil {
        log.warning("No auth token found — running in legacy mode (unauthenticated). Set \(tokenEnvVar, privacy: .public) or place a token at \(tokenFilePath, privacy: .public).")
    }

    return AgentTokens(admin: admin, runner: runner, readOnly: readOnly)
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
        AgentHTTPServer.listen(
            port: agentPort,
            adminToken: tokens.admin,
            runnerToken: tokens.runner,
            readonlyToken: tokens.readOnly
        )
    }
}
