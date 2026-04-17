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

import CryptoKit
import Foundation
import os
import Security
import SpookApplication
import SpookCore

// MARK: - Constants

/// The vsock port for the read-only channel, matching ``VsockProvisioner/agentPort``.
///
/// Serves health checks and GET-only endpoints. This is the default
/// port that existing host-side code connects to.
private let readonlyPort: UInt32 = 9470

/// The vsock port for the runner channel.
///
/// Serves read-only endpoints plus mutation endpoints (launch/quit apps,
/// set clipboard, upload files). Does NOT permit exec.
private let runnerPort: UInt32 = 9471

/// The vsock port for the break-glass channel.
///
/// Serves all endpoints including exec. Requires explicit break-glass
/// authorization at the token layer as well.
private let breakGlassPort: UInt32 = 9472

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
    /// Required — agent refuses to start without this token.
    let admin: String?
    /// Runner token — grants mutation access (launch/quit apps, clipboard, files)
    /// but NOT exec. `nil` means no runner token configured.
    let runner: String?
    /// Read-only token — grants access to GET endpoints only.
    /// `nil` means no read-only token configured.
    let readOnly: String?
}

/// Loads agent authentication tokens with the following priority:
///
/// Token loading priority:
/// 1. macOS Keychain (service: "com.spooktacular.agent")
/// 2. Token file at `/Volumes/My Shared Files/.agent-token`
/// 3. Environment variables (`SPOOK_AGENT_TOKEN`, etc.)
///
/// The first source that provides an admin token wins; lower-priority
/// sources are not consulted. Runner and read-only tokens are loaded
/// from the same source as the admin token.
///
/// If no admin token is found from any source, the agent runs in legacy
/// mode (no authentication) and a warning is logged.
///
/// - Returns: The loaded tokens.
private func loadTokens() -> AgentTokens {
    var admin: String?
    var runner: String?
    var readOnly: String?

    // Priority 1: Keychain (most secure)
    admin = keychainLoad(account: "admin-token")
    runner = keychainLoad(account: "runner-token")
    readOnly = keychainLoad(account: "readonly-token")

    if admin != nil {
        log.notice("Loaded tokens from Keychain")
        return AgentTokens(admin: admin, runner: runner, readOnly: readOnly)
    }

    // Priority 2: Token file (legacy, less secure)
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

    // Priority 3: Environment variables
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
        log.fault("No admin token found. The agent requires at least a break-glass token. Set \(tokenEnvVar, privacy: .public), store in Keychain, or place at \(tokenFilePath, privacy: .public).")
        exit(1)
    }

    return AgentTokens(admin: admin, runner: runner, readOnly: readOnly)
}

/// Loads a token from the macOS Keychain.
///
/// Queries the Keychain for a generic password item under the
/// `com.spooktacular.agent` service with the given account name.
///
/// - Parameter account: The Keychain account name (e.g. `"admin-token"`).
/// - Returns: The token string, or `nil` if not found.
private func keychainLoad(account: String) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.spooktacular.agent",
        kSecAttrAccount as String: account,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
          let token = String(data: data, encoding: .utf8) else {
        return nil
    }
    return token.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Load the OWASP-aligned break-glass ticket verifier if
        // the operator configured one. Both env vars must be
        // present; missing either means "no ticket path" rather
        // than a half-active configuration.
        AgentHTTPServer.ticketVerifier = loadTicketVerifier()

        log.notice("spooktacular-agent starting: readonly=\(readonlyPort), runner=\(runnerPort), breakGlass=\(breakGlassPort), tickets=\(AgentHTTPServer.ticketVerifier != nil ? "enabled" : "disabled")")
        AgentHTTPServer.listenAll(
            readonlyPort: readonlyPort,
            runnerPort: runnerPort,
            breakGlassPort: breakGlassPort,
            adminToken: tokens.admin,
            runnerToken: tokens.runner,
            readonlyToken: tokens.readOnly
        )
    }

    /// Loads a `BreakGlassTicketVerifier` from the environment,
    /// or returns `nil` if the operator hasn't configured one.
    ///
    /// Required env vars:
    ///   - `SPOOK_BREAKGLASS_PUBLIC_KEY` — path to a raw 32-byte
    ///     Ed25519 public key (the output of
    ///     `spook break-glass keygen --public-key`)
    ///   - `SPOOK_BREAKGLASS_ISSUERS` — comma-separated list of
    ///     operator identities that may mint tickets
    ///   - `SPOOK_BREAKGLASS_TENANT` — the tenant this agent
    ///     belongs to; tickets issued for another tenant are
    ///     rejected even if otherwise valid
    ///
    /// Any missing var → `nil` (ticket path disabled).
    /// Malformed key material → `nil` + a fault log so the
    /// operator sees the misconfiguration at boot rather than
    /// discovering it mid-incident.
    private static func loadTicketVerifier() -> BreakGlassTicketVerifier? {
        let env = ProcessInfo.processInfo.environment
        guard let keyPath = env["SPOOK_BREAKGLASS_PUBLIC_KEY"],
              let issuersRaw = env["SPOOK_BREAKGLASS_ISSUERS"],
              let tenantRaw = env["SPOOK_BREAKGLASS_TENANT"]
        else { return nil }

        guard let keyData = try? Data(contentsOf: URL(filePath: keyPath)),
              let pubKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        else {
            log.fault("SPOOK_BREAKGLASS_PUBLIC_KEY at '\(keyPath, privacy: .public)' missing or malformed — ticket path disabled")
            return nil
        }

        let issuers = Set(issuersRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !issuers.isEmpty else {
            log.fault("SPOOK_BREAKGLASS_ISSUERS is empty — ticket path disabled")
            return nil
        }

        return BreakGlassTicketVerifier(
            publicKey: pubKey,
            allowedIssuers: issuers,
            tenant: TenantID(tenantRaw),
            cache: UsedTicketCache()
        )
    }
}
