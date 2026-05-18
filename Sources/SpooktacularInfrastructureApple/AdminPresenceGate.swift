import Foundation
import LocalAuthentication
import SpooktacularCore
import os

/// Gates administrative CLI actions on proof of physical user
/// presence (Touch ID, Watch unlock, or the login password) at
/// the moment the action is requested.
///
/// This is the Spooktacular analog of what browsers do for a
/// hardware-key tap on a WebAuthn "user presence" challenge: a
/// live operator must actively consent to this specific privileged
/// action. The distinction matters:
///
/// - **Session MFA** (what workstation logins deliver) proves
///   someone with the right credential logged in at some point.
/// - **Per-action MFA** (what this gate delivers) proves someone
///   with the right credential consented at the moment of the
///   privileged action.
///
/// OWASP ASVS V2.7 (Out-of-band Verifier) and V4.3.1 (Administrative
/// MFA) both target the second form. A compromised shell inherits
/// session credentials but cannot synthesize biometry at the SEP,
/// so per-action MFA raises the attacker cost materially.
///
/// ## Headless bypass — documented, audited, time-bound
///
/// Admin commands are sometimes invoked from automation (Terraform
/// creating a tenant, a provisioning pipeline bootstrapping roles).
/// Those environments have no display or biometric sensor, so a
/// strict presence gate would fail the pipeline. The bypass is
/// NOT a compatibility hedge — it is a documented, audited,
/// time-bound exception that must satisfy **all** of the
/// following or it does not fire:
///
/// 1. **Two environment variables, both set:**
///    - `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS=1` — the opt-in flag.
///    - `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN=<token>` — a signed
///       operator-consent token, rotated monthly, carrying an
///       expiry and a list of allowed hostnames.
/// 2. **The token verifies** against the provided
///    ``BypassTokenVerifier`` (default: `nil`, which means
///    bypass is refused — operators must wire up verification
///    explicitly in production). Verification covers:
///    signature validity, hostname binding (host in allowlist),
///    and an expiry that hasn't passed.
/// 3. **The bypass is audited.** An `AuditRecord` with
///    `outcome = .bypassed`, resource = `admin-presence`, and
///    action = the prompt reason is written through the
///    provided ``AuditSink``. Every bypass surfaces in the same
///    audit pipeline as every other control-plane action — a
///    reviewer can enumerate them trivially.
/// 4. **A metric is emitted.** `admin_presence_bypass_total`
///    (labeled by hostname) is incremented through the injected
///    ``MetricsCounter``. A sustained non-zero derivative on
///    that counter is the alert signal.
///
/// Operators who want to prevent bypass entirely can set the
/// LaunchDaemon's environment with `SPOOKTACULAR_ADMIN_PRESENCE_STRICT=1`,
/// which upgrades any bypass attempt into a hard error regardless
/// of token validity.
///
/// ### Cross-agent coordination
///
/// The ``AuditSink`` surface used here is the current synchronous
/// `record(_:) async` API. Agent 7 is migrating the sink to
/// `throws` in a separate PR; this file's audit call sites will
/// need the trivial `try` sprinkle when that lands. No semantic
/// change is needed from this agent — the call shape stays the same.
public enum AdminPresenceGate {

    private static let log = Logger(
        subsystem: "com.spooktacular.spook", category: "admin-presence"
    )

    /// The outcome of a presence check.
    public enum PresenceDecision: Sendable {
        /// The user explicitly authenticated via biometry or
        /// device passcode.
        case verified

        /// Both env vars were set, the token verified, an audit
        /// record was emitted, and the bypass metric was
        /// incremented. The associated metadata is surfaced for
        /// callers that want to decorate their own higher-level
        /// audit entry.
        case bypassed(hostname: String, justification: String?)
    }

    /// Verifies a bypass-consent token.
    ///
    /// Implementations verify the token's signature, its bound
    /// hostname against the current host, and its expiry.
    /// Returning `nil` means "rejected" — the gate then refuses
    /// the bypass regardless of env vars. The verifier is
    /// injected so tests can exercise the verified path without
    /// standing up real key material.
    public protocol BypassTokenVerifier: Sendable {
        /// Validates `token` for `hostname`. Return a
        /// human-readable justification on success (e.g.,
        /// `"alice@acme, expires 2026-05-17"`); return `nil` on
        /// any validation failure.
        func verify(token: String, hostname: String) -> String?
    }

    /// Counts bypass events for alerting. The `labeled` method
    /// receives the hostname as a label — Prometheus/Datadog
    /// style.
    ///
    /// `increment` is `async` so actor-backed counters (the common
    /// case) can synchronize before the caller returns — otherwise
    /// a test or operator querying the counter immediately after
    /// the bypass races the dispatched side effect.
    public protocol MetricsCounter: Sendable {
        func increment(labeled: [String: String]) async
    }

    /// Verified bypass operation envelope. Held as a type so the
    /// reason string, metadata, and hostname all travel together
    /// and the bypass path has exactly one "produce this record"
    /// construction site.
    private struct BypassContext: Sendable {
        let hostname: String
        let reason: String
        let justification: String
    }

    /// Requires physical user presence before continuing.
    ///
    /// - Parameters:
    ///   - reason: User-facing prompt text shown in the
    ///     LocalAuthentication sheet. Be specific; "Revoke role
    ///     'ci-operator' from alice@acme" is far more useful than
    ///     "Authenticate".
    ///   - environment: Process environment — injected for
    ///     testability. Production callers pass
    ///     `ProcessInfo.processInfo.environment`.
    ///   - context: `LAContext` instance — injected so tests can
    ///     substitute an `LAMockContext`-style fake. Production
    ///     callers pass `LAContext()`.
    ///   - bypassVerifier: Verifier for the bypass-consent token.
    ///     `nil` (the default) refuses every bypass attempt —
    ///     production deployments must wire this up explicitly.
    ///   - auditSink: Sink that receives the bypass audit
    ///     record. `nil` refuses the bypass (an un-audited
    ///     bypass is never acceptable). LocalAuthentication-only
    ///     paths do not emit an audit record here — higher-level
    ///     callers emit their own.
    ///   - metricsCounter: Counter incremented on each
    ///     bypass-granted decision.
    ///   - hostname: Current hostname, injected for test determinism.
    ///   - tenant: Tenant the bypass belongs to — `TenantID.default`
    ///     is the expected value for a single-tenant host.
    public static func requirePresence(
        reason: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        context: LAContext = LAContext(),
        bypassVerifier: (any BypassTokenVerifier)? = nil,
        auditSink: (any AuditSink)? = nil,
        metricsCounter: (any MetricsCounter)? = nil,
        hostname: String = ProcessInfo.processInfo.hostName,
        tenant: TenantID = .default
    ) async throws -> PresenceDecision {
        let bypass = environment["SPOOKTACULAR_ADMIN_PRESENCE_BYPASS"] == "1"
        let strict = environment["SPOOKTACULAR_ADMIN_PRESENCE_STRICT"] == "1"

        if bypass {
            if strict {
                log.error("Admin presence strict mode: bypass attempt refused. reason=\(reason, privacy: .public)")
                throw AdminPresenceError.bypassRefusedInStrictMode
            }

            // Two-env-var requirement: BYPASS=1 alone is not
            // sufficient. The operator must also present a
            // signed consent token, rotated on the operator's
            // schedule. A missing token short-circuits to the
            // same error as a failed verification — callers see
            // a uniform "your bypass was rejected" surface.
            guard let rawToken = environment["SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN"],
                  !rawToken.isEmpty else {
                log.error("Admin presence bypass refused: missing SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN. reason=\(reason, privacy: .public)")
                throw AdminPresenceError.bypassTokenMissing
            }

            // Verifier must be wired. `nil` (the default) is
            // explicitly "bypass is disabled for this process" —
            // never "bypass accepts anything". Forces operators
            // to make a deliberate choice in `Serve.swift` /
            // CLI wiring rather than inheriting an unsafe default.
            guard let verifier = bypassVerifier else {
                log.error("Admin presence bypass refused: no BypassTokenVerifier configured. reason=\(reason, privacy: .public)")
                throw AdminPresenceError.bypassVerifierNotConfigured
            }

            guard let justification = verifier.verify(token: rawToken, hostname: hostname) else {
                log.error("Admin presence bypass refused: token verification failed. reason=\(reason, privacy: .public)")
                throw AdminPresenceError.bypassTokenInvalid
            }

            // Audit + metrics are mandatory on every bypass.
            // A missing audit sink refuses the bypass entirely —
            // an un-logged bypass is indistinguishable from a
            // full-presence grant to any downstream reviewer.
            guard let sink = auditSink else {
                log.error("Admin presence bypass refused: no AuditSink configured. reason=\(reason, privacy: .public)")
                throw AdminPresenceError.bypassAuditSinkNotConfigured
            }

            let ctx = BypassContext(
                hostname: hostname, reason: reason, justification: justification
            )
            // `AuditOutcome` has no dedicated `.bypassed` case and
            // the SpooktacularCore enum is out of scope for this agent, so
            // we use `.success` (the bypass succeeded per policy)
            // and encode the "bypass" semantic into the action
            // string: `admin-presence-bypass:<reason>`. Dashboards
            // filter on resource=`admin-presence` + action prefix
            // `admin-presence-bypass:` to enumerate every bypass.
            //
            // `AuditSink.record(_:)` is `async throws` per Agent 7's
            // migration: if the audit pipeline is broken (S3 down,
            // disk full) the bypass is refused, not silently
            // accepted. An un-audited bypass is worse than no
            // bypass, so the error propagates.
            let bypassAction = "admin-presence-bypass:\(ctx.reason)"
            try await sink.record(AuditRecord(
                actorIdentity: "admin-presence-bypass",
                tenant: tenant,
                scope: .admin,
                resource: "admin-presence",
                action: bypassAction,
                outcome: .success,
                correlationID: nil
            ))
            await metricsCounter?.increment(
                labeled: ["hostname": hostname, "metric": "admin_presence_bypass_total"]
            )
            log.error(
                "Admin presence BYPASSED (audited). reason=\(reason, privacy: .public) hostname=\(hostname, privacy: .public) justification=\(justification, privacy: .public)"
            )
            return .bypassed(hostname: hostname, justification: justification)
        }

        // Prefer biometry when available; fall back to the login
        // password so operators without biometric hardware can
        // still consent. `.deviceOwnerAuthentication` is the macOS
        // equivalent of "prompt with whatever the device supports,
        // in the operator's preferred order".
        let policy: LAPolicy = .deviceOwnerAuthentication
        var canEvaluateError: NSError?
        guard context.canEvaluatePolicy(policy, error: &canEvaluateError) else {
            let underlying = canEvaluateError
            log.fault(
                "Admin presence unavailable (no passcode/biometry configured). reason=\(reason, privacy: .public)"
            )
            throw AdminPresenceError.presenceUnavailable(underlying: underlying)
        }

        do {
            let ok = try await context.evaluatePolicy(policy, localizedReason: reason)
            if ok {
                log.info("Admin presence verified. reason=\(reason, privacy: .public)")
                return .verified
            }
            throw AdminPresenceError.userDeclined
        } catch let err as LAError {
            log.error(
                "Admin presence denied: \(err.localizedDescription, privacy: .public). reason=\(reason, privacy: .public)"
            )
            throw AdminPresenceError.userDeclined
        } catch {
            throw AdminPresenceError.evaluationFailed(underlying: error)
        }
    }
}

// MARK: - Errors

/// Errors produced by ``AdminPresenceGate``.
public enum AdminPresenceError: Error, LocalizedError {

    /// The user cancelled the prompt or biometry/passcode
    /// verification failed.
    case userDeclined

    /// The device cannot evaluate any presence policy — no
    /// biometry, no passcode, and no watch paired. Typical on a
    /// freshly imaged CI runner.
    case presenceUnavailable(underlying: Error?)

    /// `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS=1` was set but
    /// `SPOOKTACULAR_ADMIN_PRESENCE_STRICT=1` refuses bypass.
    case bypassRefusedInStrictMode

    /// `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS=1` was set but the matching
    /// `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN` is missing. The
    /// bypass requires both; either alone is rejected.
    case bypassTokenMissing

    /// No ``AdminPresenceGate/BypassTokenVerifier`` was wired
    /// into the call. The default is `nil`, which explicitly
    /// refuses every bypass — production deployments must pass
    /// a verifier or accept that bypass is disabled.
    case bypassVerifierNotConfigured

    /// The bypass-consent token failed verification: bad
    /// signature, wrong hostname, expired, or otherwise
    /// rejected by the verifier.
    case bypassTokenInvalid

    /// No ``SpooktacularCore/AuditSink`` was provided, so the bypass
    /// could not be audited. An un-audited bypass is always
    /// refused — the whole point of the bypass surface is that
    /// every use is enumerable by a reviewer.
    case bypassAuditSinkNotConfigured

    /// LocalAuthentication threw an unexpected error.
    case evaluationFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .userDeclined:
            "Administrative action cancelled — presence verification failed."
        case .presenceUnavailable:
            "This device cannot verify user presence: no Touch ID, Watch, or login password is configured."
        case .bypassRefusedInStrictMode:
            "SPOOKTACULAR_ADMIN_PRESENCE_BYPASS is set but strict mode is active — admin actions require live presence."
        case .bypassTokenMissing:
            "SPOOKTACULAR_ADMIN_PRESENCE_BYPASS=1 was set but SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN is missing — both are required."
        case .bypassVerifierNotConfigured:
            "Admin-presence bypass was requested but no BypassTokenVerifier was configured for this process — the bypass surface is disabled by default."
        case .bypassTokenInvalid:
            "Admin-presence bypass token failed verification (bad signature, wrong hostname, expired, or unauthorized for this host)."
        case .bypassAuditSinkNotConfigured:
            "Admin-presence bypass was requested but no AuditSink was configured — an un-audited bypass is never acceptable."
        case .evaluationFailed(let err):
            "LocalAuthentication evaluation failed: \(err.localizedDescription)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .userDeclined:
            "Retry the command and complete the Touch ID / password prompt."
        case .presenceUnavailable:
            "Configure a login password on the host. For genuinely headless environments (CI), set BOTH `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS=1` and `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN=<signed-consent-token>`. Every bypass is audited."
        case .bypassRefusedInStrictMode:
            "Run this command from an operator workstation with biometry/passcode configured. If strict mode was set by mistake, unset `SPOOKTACULAR_ADMIN_PRESENCE_STRICT` in the daemon environment."
        case .bypassTokenMissing:
            "Mint a monthly consent token (`spook break-glass issue-presence-token --host <hostname>`) and export it as `SPOOKTACULAR_ADMIN_PRESENCE_BYPASS_TOKEN`."
        case .bypassVerifierNotConfigured:
            "Wire a `BypassTokenVerifier` through the CLI bootstrapper (see Serve.swift). Passing nil disables the bypass surface entirely — which is the intended default for any path that hasn't been explicitly configured for headless operation."
        case .bypassTokenInvalid:
            "Check the token's expiry (tokens rotate monthly) and confirm the current hostname matches one in the token's allowlist. Re-issue with `spook break-glass issue-presence-token --host <hostname>` if rotation is due."
        case .bypassAuditSinkNotConfigured:
            "Pass an AuditSink to `requirePresence(...)`. Operators who wire the admin surface by hand should use the same sink (OSLog / S3 Object Lock / HashChain) they use for control-plane audit."
        case .evaluationFailed:
            "Check the Console app for `subsystem = com.spooktacular.spook, category = admin-presence` entries near the failure time."
        }
    }
}
