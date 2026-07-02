import CryptoKit
import Foundation
import os
import SpooktacularApplication
import SpooktacularCore

/// Public façade over the guest-agent HTTP/vsock server stack.
///
/// The sole consumer is the Spooktacular Guest Tools `.app`
/// (menu-bar app running per-user in each guest VM).
///
/// ## Blocking contract
///
/// ``run()`` starts four vsock listeners (readonly, runner,
/// tunnel, break-glass) and blocks the calling thread for the
/// process lifetime. Callers should invoke it from a dedicated
/// detached task or the process `@main`.
///
/// > The break-glass listener holds the calling thread for the
/// > server's lifetime; there's no cancellation-aware async
/// > shutdown today. The Guest Tools app relies on process exit
/// > when the user quits the menu-bar extra. Add an async API
/// > here when a real shutdown-on-quit requirement surfaces.
///
/// ## Host-trust configuration
///
/// Reads three environment variables to configure auth (same
/// names preserved from the pre-refactor CLI — mechanical
/// refactor only):
///
/// - `SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR` — directory of
///   PEM-encoded P-256 public keys. Any key in this directory
///   authorizes one host identity for signed-request auth on
///   readonly + runner channels.
/// - `SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR` +
///   `SPOOKTACULAR_BREAKGLASS_ISSUERS` +
///   `SPOOKTACULAR_BREAKGLASS_TENANT` — break-glass ticket
///   verification (one-shot operator overrides). All three
///   required; missing any disables the ticket path.
/// - `SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1` — legacy escape
///   hatch for local dev. Skips the "must have at least one
///   auth path" check. Logged loudly.
public struct GuestAgentServer: Sendable {

    /// vsock ports for the three auth channels. Matches
    /// `VsockProvisioner/agentPort` / `runnerPort` /
    /// `breakGlassPort` on the host.
    public static let readonlyPort: UInt32 = 9470
    public static let runnerPort: UInt32 = 9471
    public static let breakGlassPort: UInt32 = 9472

    private static let log = Logger(
        subsystem: "com.spooktacular.agent",
        category: "agent"
    )

    /// Tri-state policy governing what the server does when
    /// neither a host-signature verifier nor a break-glass
    /// verifier is configured.
    public enum AuthPolicy: Sendable {
        /// Refuse to start unless at least one verifier is
        /// configured OR the operator opts in via
        /// `SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1`. The legacy
        /// multi-tenant default — guards against
        /// misconfiguration in operator-managed deployments.
        case requireAuth

        /// Start in no-auth mode unconditionally. The trust
        /// model is "vsock is a host-private channel; the host
        /// already has code execution authority over the
        /// guest". Appropriate for the single-user
        /// `SpooktacularGuestTools.app` deployment, where
        /// per-VM key provisioning would be friction without
        /// a corresponding security boundary.
        case trustedHost
    }

    private let authPolicy: AuthPolicy

    public init(authPolicy: AuthPolicy = .requireAuth) {
        self.authPolicy = authPolicy
    }

    /// Publishes a ``SpiceStatusProvider`` to the HTTP router
    /// so `GET /api/v1/spice/status` can return a live
    /// snapshot of the in-process SPICE clipboard bridge.
    ///
    /// Call this before ``run()`` — the setter is
    /// idempotent, so a second call simply swaps the
    /// provider. Pass `nil` to deregister (the endpoint
    /// then reports ``SpiceClipboardState/notStarted``).
    public static func setSpiceStatusProvider(
        _ provider: (any SpiceStatusProvider)?
    ) {
        AgentHTTPServer.spiceStatusProvider = provider
    }

    /// Pushes a ``GuestEvent`` onto the outbound
    /// vsock-to-host event stream. The event is coalesced
    /// per topic (most-recent wins) and delivered on the
    /// next write opportunity; events posted during a
    /// reconnect window are buffered and flushed on
    /// reconnect so the host never lags.
    ///
    /// Intended for cross-subsystem push notifications the
    /// guest-tools app composes — today's sole caller is
    /// `AgentController`, which posts
    /// ``SpooktacularCore/GuestEvent/spiceStatus(_:)`` on
    /// every SPICE clipboard-bridge state transition.
    public static func postEvent(_ event: GuestEvent) {
        HostEventDialer.post(event)
    }

    /// Starts the guest-agent server and blocks until the
    /// process terminates. Throws if neither a host-signature
    /// verifier nor a break-glass verifier is configured AND
    /// the operator hasn't opted in to no-auth mode via
    /// `SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1`.
    public func run() throws {
        AgentHTTPServer.signatureVerifier = Self.loadSignatureVerifier()
        AgentHTTPServer.ticketVerifier = Self.loadTicketVerifier()

        if AgentHTTPServer.signatureVerifier == nil,
           AgentHTTPServer.ticketVerifier == nil {
            switch authPolicy {
            case .trustedHost:
                Self.log.notice("Agent starting in trusted-host mode — vsock is a host-private channel; no cryptographic auth between host and guest.")
            case .requireAuth:
                let env = ProcessInfo.processInfo.environment
                let envEscape = env["SPOOKTACULAR_AGENT_ALLOW_NO_AUTH"] == "1"
                if envEscape {
                    Self.log.fault("Agent starting in NO-AUTH legacy mode (SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1). DO NOT USE IN PRODUCTION.")
                } else {
                    Self.log.fault("Agent refuses to start: neither SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR nor SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR is configured.")
                    throw GuestAgentServerError.authNotConfigured
                }
            }
        }

        Self.log.notice(
            "guest-agent starting: readonly=\(Self.readonlyPort), runner=\(Self.runnerPort), breakGlass=\(Self.breakGlassPort), signatures=\(AgentHTTPServer.signatureVerifier != nil ? "enabled" : "disabled"), tickets=\(AgentHTTPServer.ticketVerifier != nil ? "enabled" : "disabled")"
        )

        // Apple-native event push. Dials the host's
        // `VZVirtioSocketListener` on port 9469 and streams
        // length-prefixed `GuestEvent` frames. Runs on a
        // detached thread alongside the HTTP listeners so
        // request/response RPCs (exec, clipboard, apps, …)
        // keep their HTTP path.
        HostEventDialer.start()
        // Blocks the calling thread forever. Returning this
        // expression would require the function be `-> Never`,
        // but a throwing Never isn't expressible in Swift — we
        // keep the throw-then-block shape instead.
        AgentHTTPServer.listenAll(
            readonlyPort: Self.readonlyPort,
            runnerPort: Self.runnerPort,
            breakGlassPort: Self.breakGlassPort
        )
    }

    // MARK: - Host trust loading

    /// Loads the operator-provisioned allowlist of host public
    /// keys from `SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR`. Returns
    /// `nil` if unconfigured or empty — the caller treats that
    /// as "signature path disabled".
    static func loadSignatureVerifier() -> SignedRequestVerifier? {
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

    /// Loads a `BreakGlassTicketVerifier` from the environment,
    /// or returns `nil` if the operator hasn't configured one.
    /// Requires all three env vars; missing any → disabled.
    static func loadTicketVerifier() -> BreakGlassTicketVerifier? {
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

/// Errors thrown by ``GuestAgentServer/run()`` during startup.
public enum GuestAgentServerError: Error, Sendable, LocalizedError {
    /// Neither a host-signature verifier nor a break-glass
    /// verifier is configured, and the operator has not
    /// opted in to no-auth mode.
    case authNotConfigured

    public var errorDescription: String? {
        switch self {
        case .authNotConfigured:
            return "Guest-agent refuses to start: neither SPOOKTACULAR_HOST_PUBLIC_KEYS_DIR (host signature trust) nor SPOOKTACULAR_BREAKGLASS_PUBLIC_KEYS_DIR (break-glass tickets) is configured. Set at least one, or explicitly opt in to the legacy no-auth mode with SPOOKTACULAR_AGENT_ALLOW_NO_AUTH=1."
        }
    }
}
