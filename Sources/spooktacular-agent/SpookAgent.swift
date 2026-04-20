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
import SpooktacularApplication
import SpooktacularCore

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

/// Logger for the guest agent.
private let log = Logger(subsystem: "com.spooktacular.agent", category: "agent")

// MARK: - Host trust loading

/// Loads the operator-provisioned allowlist of host public keys
/// from `SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR`.
///
/// Every `.pem` / `.pub` file in the directory is treated as a
/// PEM-SPKI P-256 public key that authorizes one host identity.
/// A successful signature from any of these keys is accepted on
/// the readonly + runner channels.
///
/// Onboarding a new controller: drop its `.pem` into the dir
/// and SIGHUP / restart the agent.
/// Offboarding: delete its `.pem` and restart.
///
/// Returns `nil` if the dir is unset, missing, or contains no
/// valid PEMs — the caller treats `nil` as "signature path
/// disabled" and falls back to legacy no-auth mode (with a
/// loud warning).
private func loadSignatureVerifier() -> SignedRequestVerifier? {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR"] else {
        return nil
    }

    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
        log.fault("SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR at '\(dir, privacy: .public)' is not a directory — signature path disabled")
        return nil
    }

    let names: [String]
    do {
        names = try fm.contentsOfDirectory(atPath: dir)
    } catch {
        log.fault("Cannot enumerate \(dir, privacy: .public): \(error.localizedDescription, privacy: .public) — signature path disabled")
        return nil
    }

    var keys: [P256.Signing.PublicKey] = []
    for name in names where name.hasSuffix(".pem") || name.hasSuffix(".pub") {
        let path = (dir as NSString).appendingPathComponent(name)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            log.error("Unreadable host key file: \(name, privacy: .public) — skipping")
            continue
        }
        do {
            let key = try P256.Signing.PublicKey(pemRepresentation: text)
            keys.append(key)
        } catch {
            log.error("Malformed PEM in \(name, privacy: .public): \(error.localizedDescription, privacy: .public) — skipping")
            continue
        }
    }

    guard !keys.isEmpty else {
        log.fault("SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR at '\(dir, privacy: .public)' has no valid PEM files — signature path disabled")
        return nil
    }

    log.info("Host signature verifier ready: \(keys.count, privacy: .public) trusted host key(s) loaded")
    return SignedRequestVerifier(trustedKeys: keys)
}

// MARK: - Entry Point

/// Parses command-line arguments and either installs a LaunchDaemon/Agent
/// or starts the HTTP API server.
@main
enum SpooktacularAgent {
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

        // Load the host-identity signature verifier + the
        // OWASP-aligned break-glass ticket verifier. Either can
        // be absent; the agent refuses to start if BOTH are
        // absent unless `SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1` is set
        // (legacy local-dev escape hatch).
        AgentHTTPServer.signatureVerifier = loadSignatureVerifier()
        AgentHTTPServer.ticketVerifier = loadTicketVerifier()

        let env = ProcessInfo.processInfo.environment
        let noAuthEscape = env["SPOOKTACULAR_AGENT_ALLOW_NO_AUTH"] == "1"

        if AgentHTTPServer.signatureVerifier == nil && AgentHTTPServer.ticketVerifier == nil {
            if noAuthEscape {
                log.fault("Agent starting in NO-AUTH legacy mode (SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1). All non-break-glass requests are unauthenticated. DO NOT USE IN PRODUCTION.")
            } else {
                log.fault("Agent refuses to start: neither SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR (host signature trust) nor SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR (break-glass tickets) is configured. Set at least one, or explicitly opt in to the legacy no-auth mode with SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1.")
                exit(1)
            }
        }

        log.notice(
            "spooktacular-agent starting: readonly=\(readonlyPort), runner=\(runnerPort), breakGlass=\(breakGlassPort), signatures=\(AgentHTTPServer.signatureVerifier != nil ? "enabled" : "disabled"), tickets=\(AgentHTTPServer.ticketVerifier != nil ? "enabled" : "disabled")"
        )
        AgentHTTPServer.listenAll(
            readonlyPort: readonlyPort,
            runnerPort: runnerPort,
            breakGlassPort: breakGlassPort
        )
    }

    /// Loads a `BreakGlassTicketVerifier` from the environment,
    /// or returns `nil` if the operator hasn't configured one.
    ///
    /// Required env vars:
    ///   - `SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR` — directory
    ///     containing one or more PEM-encoded P-256 public keys
    ///     (files ending in `.pem` or `.pub`). Each file names
    ///     one trusted operator. The verifier accepts a ticket
    ///     if its signature matches any one of these keys.
    ///   - `SPOOKTACULAR_BREAKGLASS_ISSUERS` — comma-separated list of
    ///     operator identities that may mint tickets. Checked
    ///     as a secondary allowlist alongside the cryptographic
    ///     key match.
    ///   - `SPOOKTACULAR_BREAKGLASS_TENANT` — the tenant this agent
    ///     belongs to; tickets issued for another tenant are
    ///     rejected even if otherwise valid.
    ///
    /// Any missing var → `nil` (ticket path disabled).
    /// Malformed key material → `nil` + a fault log so the
    /// operator sees the misconfiguration at boot rather than
    /// discovering it mid-incident. An empty keys directory
    /// also disables the ticket path (better than silently
    /// accepting nothing).
    private static func loadTicketVerifier() -> BreakGlassTicketVerifier? {
        let env = ProcessInfo.processInfo.environment
        guard let keysDir = env["SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR"],
              let issuersRaw = env["SPOOKTACULAR_BREAKGLASS_ISSUERS"],
              let tenantRaw = env["SPOOKTACULAR_BREAKGLASS_TENANT"]
        else { return nil }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: keysDir, isDirectory: &isDir), isDir.boolValue else {
            log.fault("SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR at '\(keysDir, privacy: .public)' is not a directory — ticket path disabled")
            return nil
        }

        let contents: [String]
        do {
            contents = try fm.contentsOfDirectory(atPath: keysDir)
        } catch {
            log.fault("Cannot enumerate \(keysDir, privacy: .public): \(error.localizedDescription, privacy: .public) — ticket path disabled")
            return nil
        }

        var publicKeys: [P256.Signing.PublicKey] = []
        for name in contents where name.hasSuffix(".pem") || name.hasSuffix(".pub") {
            let path = (keysDir as NSString).appendingPathComponent(name)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                log.error("Unreadable break-glass key file: \(name, privacy: .public) — skipping")
                continue
            }
            do {
                let key = try P256.Signing.PublicKey(pemRepresentation: text)
                publicKeys.append(key)
            } catch {
                log.error("Malformed PEM in \(name, privacy: .public): \(error.localizedDescription, privacy: .public) — skipping")
                continue
            }
        }

        guard !publicKeys.isEmpty else {
            log.fault("SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR at '\(keysDir, privacy: .public)' has no valid PEM files — ticket path disabled")
            return nil
        }

        let issuers = Set(issuersRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        guard !issuers.isEmpty else {
            log.fault("SPOOKTACULAR_BREAKGLASS_ISSUERS is empty — ticket path disabled")
            return nil
        }

        log.info("Break-glass verifier ready: \(publicKeys.count, privacy: .public) trusted operator key(s) loaded")

        return BreakGlassTicketVerifier(
            publicKeys: publicKeys,
            allowedIssuers: issuers,
            tenant: TenantID(tenantRaw),
            cache: UsedTicketCache()
        )
    }
}
