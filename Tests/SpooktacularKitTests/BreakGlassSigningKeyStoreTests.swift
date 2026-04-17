import Testing
import Foundation
import CryptoKit
@testable import SpookInfrastructureApple

/// Tests for ``BreakGlassSigningKeyStore``.
///
/// The store's hot path — `store(label:)` + `loadSigner(...)` —
/// requires both a Secure Enclave *and* a live user gesture
/// (Touch ID or the login password). Neither is available under
/// `swift test` on headless CI, so round-trip is covered by
/// manual / integration testing. What we can pin here is the
/// deterministic surface:
///
/// - The error taxonomy covers the operator-visible failure modes.
/// - Invalid inputs are rejected before the Keychain is touched.
/// - `exists(label:)` returns `false` for an unused label without
///   prompting.
@Suite("BreakGlassSigningKeyStore", .tags(.security, .cryptography))
struct BreakGlassSigningKeyStoreTests {

    @Test("Empty label is rejected on store")
    func emptyLabelOnStore() {
        #expect(throws: BreakGlassSigningKeyStoreError.self) {
            _ = try BreakGlassSigningKeyStore.store(label: "")
        }
    }

    @Test("Empty label is rejected on loadSigner")
    func emptyLabelOnLoad() async {
        await #expect(throws: BreakGlassSigningKeyStoreError.self) {
            _ = try await BreakGlassSigningKeyStore.loadSigner(label: "", reason: "test")
        }
    }

    @Test("Empty label is rejected on publicKey")
    func emptyLabelOnPublicKey() {
        #expect(throws: BreakGlassSigningKeyStoreError.self) {
            _ = try BreakGlassSigningKeyStore.publicKey(label: "")
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

        let dup = BreakGlassSigningKeyStoreError.alreadyExists(label: "alice-mbp")
        #expect(dup.errorDescription?.contains("alice-mbp") == true)
        #expect(dup.recoverySuggestion?.contains("rotate") == true)

        // Spot-check the SEP-unavailable case since it's the one
        // reviewers will ask about for non-Apple-Silicon hosts.
        let noSEP = BreakGlassSigningKeyStoreError.secureEnclaveUnavailable(
            underlying: NSError(domain: "test", code: 0)
        )
        #expect(noSEP.errorDescription?.contains("Secure Enclave") == true)
        #expect(noSEP.recoverySuggestion?.contains("T2") == true
             || noSEP.recoverySuggestion?.contains("Apple Silicon") == true)
    }

    @Test("Service tag namespaces the item under a predictable prefix")
    func serviceNamespaced() {
        #expect(BreakGlassSigningKeyStore.service == "com.spooktacular.break-glass")
    }
}
