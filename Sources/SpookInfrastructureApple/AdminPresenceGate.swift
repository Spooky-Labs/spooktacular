import Foundation
import LocalAuthentication
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
/// ## Headless / CI escape hatch
///
/// Admin commands are sometimes invoked from automation (Terraform
/// creating a tenant, a provisioning pipeline bootstrapping roles).
/// Those environments have no display or biometric sensor, so a
/// strict presence gate would fail the pipeline. Setting the env
/// var `SPOOK_ADMIN_PRESENCE_BYPASS=1` skips the prompt. The
/// bypass is surfaced in two ways the auditor can enumerate:
///
/// 1. An `OSLog` `.error`-level audit record is written at call
///    time with privacy-public `reason` + the bypass justification
///    env var `SPOOK_ADMIN_PRESENCE_BYPASS_REASON`.
/// 2. The gate returns ``PresenceDecision/bypassed``, letting the
///    caller decide whether to down-scope the action or emit its
///    own higher-level audit entry.
///
/// Operators who want to prevent bypass entirely can set the
/// LaunchDaemon's environment with `SPOOK_ADMIN_PRESENCE_STRICT=1`,
/// which upgrades a bypass attempt into a hard error.
public enum AdminPresenceGate {

    private static let log = Logger(
        subsystem: "com.spooktacular.spook", category: "admin-presence"
    )

    /// The outcome of a presence check.
    public enum PresenceDecision: Sendable {
        /// The user explicitly authenticated via biometry or
        /// device passcode.
        case verified

        /// `SPOOK_ADMIN_PRESENCE_BYPASS=1` was set and strict mode
        /// was off; the gate was not exercised.
        case bypassed(justification: String?)
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
    public static func requirePresence(
        reason: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        context: LAContext = LAContext()
    ) async throws -> PresenceDecision {
        // Env-driven bypass (see class-level docs).
        let bypass = environment["SPOOK_ADMIN_PRESENCE_BYPASS"] == "1"
        let strict = environment["SPOOK_ADMIN_PRESENCE_STRICT"] == "1"

        if bypass {
            if strict {
                log.error("Admin presence strict mode: bypass attempt refused. reason=\(reason, privacy: .public)")
                throw AdminPresenceError.bypassRefusedInStrictMode
            }
            let justification = environment["SPOOK_ADMIN_PRESENCE_BYPASS_REASON"]
            log.error(
                "Admin presence BYPASSED. reason=\(reason, privacy: .public) justification=\(justification ?? "(none)", privacy: .public)"
            )
            return .bypassed(justification: justification)
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

    /// `SPOOK_ADMIN_PRESENCE_BYPASS=1` was set but
    /// `SPOOK_ADMIN_PRESENCE_STRICT=1` refuses bypass.
    case bypassRefusedInStrictMode

    /// LocalAuthentication threw an unexpected error.
    case evaluationFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .userDeclined:
            "Administrative action cancelled — presence verification failed."
        case .presenceUnavailable:
            "This device cannot verify user presence: no Touch ID, Watch, or login password is configured."
        case .bypassRefusedInStrictMode:
            "SPOOK_ADMIN_PRESENCE_BYPASS is set but strict mode is active — admin actions require live presence."
        case .evaluationFailed(let err):
            "LocalAuthentication evaluation failed: \(err.localizedDescription)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .userDeclined:
            "Retry the command and complete the Touch ID / password prompt."
        case .presenceUnavailable:
            "Configure a login password on the host. For genuinely headless environments (CI), set `SPOOK_ADMIN_PRESENCE_BYPASS=1` and optionally `SPOOK_ADMIN_PRESENCE_BYPASS_REASON` — every bypass is logged."
        case .bypassRefusedInStrictMode:
            "Run this command from an operator workstation with biometry/passcode configured. If strict mode was set by mistake, unset `SPOOK_ADMIN_PRESENCE_STRICT` in the daemon environment."
        case .evaluationFailed:
            "Check the Console app for `subsystem = com.spooktacular.spook, category = admin-presence` entries near the failure time."
        }
    }
}
