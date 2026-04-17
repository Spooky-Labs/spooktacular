import Testing
import Foundation
import LocalAuthentication
@testable import SpookInfrastructureApple

/// Tests for ``AdminPresenceGate``.
///
/// The live presence-verification path prompts Touch ID and
/// therefore can't run under `swift test` on headless CI. What
/// these tests pin is the deterministic surface the gate
/// exposes to the CLI:
///
/// - The env-var bypass escape hatch works as documented.
/// - Strict mode refuses bypass with a distinct error.
/// - The unavailable path (no biometry, no passcode) is
///   reported as `presenceUnavailable` rather than silently
///   granting access.
///
/// The verified path (`LAContext` returns `true`) is exercised
/// via a testing subclass of `LAContext` that short-circuits
/// the real prompt.
@Suite("AdminPresenceGate", .tags(.security, .cli))
struct AdminPresenceGateTests {

    @Test("Env-var bypass without strict mode returns .bypassed")
    func bypassEnvVar() async throws {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_BYPASS_REASON": "CI provisioning"]
        let decision = try await AdminPresenceGate.requirePresence(
            reason: "Test action",
            environment: env,
            context: LAContext()
        )
        switch decision {
        case .bypassed(let justification):
            #expect(justification == "CI provisioning")
        case .verified:
            Issue.record("Expected bypass, got verified")
        }
    }

    @Test("Bypass with strict mode throws bypassRefusedInStrictMode")
    func strictModeRefusesBypass() async {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_STRICT": "1"]
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: env,
                context: LAContext()
            )
        }
    }

    @Test("Unavailable presence (fake LAContext) surfaces presenceUnavailable")
    func unavailable() async {
        let fake = PresenceUnavailableContext()
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: [:],
                context: fake
            )
        }
    }

    @Test("Verified presence (fake LAContext) returns .verified")
    func verified() async throws {
        let fake = PresenceVerifiedContext()
        let decision = try await AdminPresenceGate.requirePresence(
            reason: "Admin action",
            environment: [:],
            context: fake
        )
        switch decision {
        case .verified:
            break
        case .bypassed:
            Issue.record("Expected verified, got bypassed")
        }
    }

    @Test("Error taxonomy provides actionable recovery guidance")
    func errorMessages() {
        let declined = AdminPresenceError.userDeclined
        #expect(declined.recoverySuggestion?.contains("Retry") == true)

        let unavail = AdminPresenceError.presenceUnavailable(underlying: nil)
        #expect(unavail.recoverySuggestion?.contains("BYPASS") == true)
    }
}

// MARK: - Test doubles

/// LAContext stand-in that claims no policy can be evaluated —
/// models a headless host without Touch ID or a login password.
private final class PresenceUnavailableContext: LAContext, @unchecked Sendable {
    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        error?.pointee = NSError(
            domain: LAErrorDomain,
            code: LAError.passcodeNotSet.rawValue,
            userInfo: nil
        )
        return false
    }
}

/// LAContext stand-in that short-circuits a successful prompt.
private final class PresenceVerifiedContext: LAContext, @unchecked Sendable {
    override func canEvaluatePolicy(_ policy: LAPolicy, error: NSErrorPointer) -> Bool {
        return true
    }

    override func evaluatePolicy(_ policy: LAPolicy, localizedReason: String) async throws -> Bool {
        return true
    }
}
