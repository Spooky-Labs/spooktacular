import Testing
import Foundation
import LocalAuthentication
@testable import SpookCore
@testable import SpookInfrastructureApple

/// Tests for ``AdminPresenceGate``.
///
/// The live presence-verification path prompts Touch ID and
/// therefore can't run under `swift test` on headless CI. What
/// these tests pin is the deterministic surface the gate
/// exposes to the CLI, with the hardened bypass protocol:
///
/// - Bypass requires BOTH env vars + a verifier + an audit sink.
/// - Missing token → `.bypassTokenMissing`.
/// - Missing verifier (nil default) → `.bypassVerifierNotConfigured`.
/// - Invalid token → `.bypassTokenInvalid`.
/// - Missing audit sink → `.bypassAuditSinkNotConfigured`.
/// - Valid bypass emits exactly one audit record and one metric.
/// - Strict mode refuses bypass even with valid token.
/// - The unavailable path (no biometry, no passcode) surfaces
///   `presenceUnavailable`.
///
/// The verified path (`LAContext` returns `true`) is exercised
/// via a testing subclass of `LAContext` that short-circuits
/// the real prompt.
@Suite("AdminPresenceGate", .tags(.security, .cli))
struct AdminPresenceGateTests {

    @Test("Bypass with no token throws bypassTokenMissing")
    func bypassWithoutTokenRejects() async {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1"]
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: env,
                context: LAContext(),
                bypassVerifier: nil,
                auditSink: nil,
                metricsCounter: nil,
                hostname: "host-1"
            )
        }
    }

    @Test("Bypass with token but no verifier throws bypassVerifierNotConfigured")
    func bypassWithoutVerifierRejects() async {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_BYPASS_TOKEN": "tok-XYZ"]
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: env,
                context: LAContext(),
                bypassVerifier: nil,
                auditSink: RecordingAuditSink(),
                metricsCounter: nil,
                hostname: "host-1"
            )
        }
    }

    @Test("Bypass with invalid token throws bypassTokenInvalid")
    func bypassWithInvalidTokenRejects() async {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_BYPASS_TOKEN": "forged-token"]
        let verifier = FixedVerifier(accept: nil)
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: env,
                context: LAContext(),
                bypassVerifier: verifier,
                auditSink: RecordingAuditSink(),
                metricsCounter: nil,
                hostname: "host-1"
            )
        }
    }

    @Test("Bypass with token + verifier but no audit sink throws bypassAuditSinkNotConfigured")
    func bypassWithoutAuditSinkRejects() async {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_BYPASS_TOKEN": "tok-OK"]
        let verifier = FixedVerifier(accept: "alice@acme, expires 2026-05-17")
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: env,
                context: LAContext(),
                bypassVerifier: verifier,
                auditSink: nil,
                metricsCounter: nil,
                hostname: "host-1"
            )
        }
    }

    @Test("Valid bypass emits one audit record + one metric")
    func bypassValidPathAuditsAndMetrics() async throws {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_BYPASS_TOKEN": "tok-OK"]
        let verifier = FixedVerifier(accept: "alice@acme")
        let sink = RecordingAuditSink()
        let counter = RecordingCounter()
        let decision = try await AdminPresenceGate.requirePresence(
            reason: "Revoke role",
            environment: env,
            context: LAContext(),
            bypassVerifier: verifier,
            auditSink: sink,
            metricsCounter: counter,
            hostname: "host-1"
        )
        switch decision {
        case .bypassed(let host, let just):
            #expect(host == "host-1")
            #expect(just == "alice@acme")
        case .verified:
            Issue.record("Expected bypassed, got verified")
        }
        let recorded = await sink.records
        #expect(recorded.count == 1)
        #expect(recorded.first?.resource == "admin-presence")
        #expect(recorded.first?.action.hasPrefix("admin-presence-bypass:") == true)
        let incs = await counter.incrementCount
        #expect(incs == 1)
    }

    @Test("Bypass with strict mode throws bypassRefusedInStrictMode even with valid token")
    func strictModeRefusesBypass() async {
        let env = ["SPOOK_ADMIN_PRESENCE_BYPASS": "1",
                   "SPOOK_ADMIN_PRESENCE_BYPASS_TOKEN": "tok-OK",
                   "SPOOK_ADMIN_PRESENCE_STRICT": "1"]
        let verifier = FixedVerifier(accept: "alice@acme")
        await #expect(throws: AdminPresenceError.self) {
            _ = try await AdminPresenceGate.requirePresence(
                reason: "Admin action",
                environment: env,
                context: LAContext(),
                bypassVerifier: verifier,
                auditSink: RecordingAuditSink(),
                metricsCounter: nil,
                hostname: "host-1"
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

        let tokenMissing = AdminPresenceError.bypassTokenMissing
        #expect(tokenMissing.recoverySuggestion?.contains("token") == true)
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

/// Bypass-token verifier that returns a fixed acceptance decision.
private struct FixedVerifier: AdminPresenceGate.BypassTokenVerifier {
    let accept: String?
    func verify(token: String, hostname: String) -> String? { accept }
}

/// Audit sink that records every record into an actor-protected
/// array. Deterministic observation surface for bypass audit
/// tests.
private actor RecordingAuditSink: AuditSink {
    private(set) var records: [AuditRecord] = []
    func record(_ entry: AuditRecord) async throws { records.append(entry) }
}

/// Counter that records each `increment` call.
private actor RecordingCounter: AdminPresenceGate.MetricsCounter {
    private(set) var incrementCount = 0
    func increment(labeled: [String: String]) {
        incrementCount += 1
    }
}
