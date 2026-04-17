import Testing
import Foundation
import CryptoKit
@testable import SpookInfrastructureApple

/// Tests for ``BreakGlassSigningKeyStore``.
///
/// The store's hot path — `store(_:label:)` + `load(label:reason:)`
/// — requires a live user gesture (Touch ID or the login password)
/// because it writes and retrieves items protected by a
/// `SecAccessControl` with `.userPresence`. Unit tests on headless
/// CI can't provide that gesture, so the Keychain round-trip is
/// covered by manual / integration testing. What we can pin here
/// is the deterministic surface:
///
/// - The error taxonomy covers the operator-visible failure modes.
/// - Invalid inputs are rejected before the Keychain is touched.
/// - `exists(label:)` returns `false` for an unused label without
///   prompting — important because the CLI uses it to prevent
///   accidental overwrites.
@Suite("BreakGlassSigningKeyStore", .tags(.security, .cryptography))
struct BreakGlassSigningKeyStoreTests {

    @Test("Empty label is rejected on store")
    func emptyLabelOnStore() {
        let key = Curve25519.Signing.PrivateKey()
        #expect(throws: BreakGlassSigningKeyStoreError.self) {
            try BreakGlassSigningKeyStore.store(key, label: "")
        }
    }

    @Test("Empty label is rejected on load")
    func emptyLabelOnLoad() {
        #expect(throws: BreakGlassSigningKeyStoreError.self) {
            _ = try BreakGlassSigningKeyStore.load(label: "", reason: "test")
        }
    }

    @Test("Empty label is rejected on delete")
    func emptyLabelOnDelete() {
        #expect(throws: BreakGlassSigningKeyStoreError.self) {
            try BreakGlassSigningKeyStore.delete(label: "")
        }
    }

    @Test("exists returns false for an unused label without prompting")
    func existsForUnusedLabel() {
        // Use a high-entropy label to guarantee absence across
        // successive test runs even on a developer machine.
        let label = "spooktacular-test-\(UUID().uuidString)"
        #expect(BreakGlassSigningKeyStore.exists(label: label) == false)
    }

    @Test("Error taxonomy surfaces actionable guidance")
    func errorMessages() {
        let notFound = BreakGlassSigningKeyStoreError.notFound(label: "bogus")
        #expect(notFound.errorDescription?.contains("bogus") == true)
        #expect(notFound.recoverySuggestion?.contains("keygen") == true)

        let declined = BreakGlassSigningKeyStoreError.userDeclined
        #expect(declined.errorDescription?.contains("cancelled") == true
             || declined.errorDescription?.contains("failed") == true)

        let dup = BreakGlassSigningKeyStoreError.alreadyExists(label: "fleet-default")
        #expect(dup.errorDescription?.contains("fleet-default") == true)
        #expect(dup.recoverySuggestion?.contains("rotate") == true)
    }

    @Test("Service tag namespaces the item under a predictable prefix")
    func serviceNamespaced() {
        #expect(BreakGlassSigningKeyStore.service == "com.spooktacular.break-glass")
    }
}
