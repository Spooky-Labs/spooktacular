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
private let tokenFilePath = "/Volumes/My Shared Files/.agent-token"

/// Environment variable name for the agent authentication token.
private let tokenEnvVar = "SPOOK_AGENT_TOKEN"

/// Logger for the guest agent.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "agent")

// MARK: - Token Loading

/// Loads the agent authentication token from the file system or environment.
///
/// The function checks the following sources in order:
/// 1. The file at ``tokenFilePath`` (``/Volumes/My Shared Files/.agent-token``).
/// 2. The ``SPOOK_AGENT_TOKEN`` environment variable.
///
/// If neither source provides a token, the agent runs in legacy mode
/// (no authentication) and a warning is logged.
///
/// - Returns: The token string, or `nil` for legacy (unauthenticated) mode.
private func loadToken() -> String? {
    // Try file first
    if let fileToken = try? String(contentsOfFile: tokenFilePath, encoding: .utf8) {
        let trimmed = fileToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            log.notice("Loaded auth token from \(tokenFilePath, privacy: .public)")
            return trimmed
        }
    }

    // Try environment variable
    if let envToken = ProcessInfo.processInfo.environment[tokenEnvVar] {
        let trimmed = envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            log.notice("Loaded auth token from environment variable \(tokenEnvVar, privacy: .public)")
            return trimmed
        }
    }

    log.warning("No auth token found — running in legacy mode (unauthenticated). Set \(tokenEnvVar, privacy: .public) or place a token at \(tokenFilePath, privacy: .public).")
    return nil
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

        let token = loadToken()
        log.notice("spooktacular-agent starting on vsock port \(agentPort)")
        AgentHTTPServer.listen(port: agentPort, token: token)
    }
}
