import Testing
import Foundation
import CryptoKit
@testable import SpookInfrastructureApple

/// Tests for ``P256KeyStore`` — the unified SEP / software
/// key-provisioning primitive used by every SEP-bound signing
/// purpose in Spooktacular.
///
/// The SEP-backed paths require both Secure Enclave hardware
/// and (for presence-gated keys) a live user gesture — neither
/// is available under `swift test` on headless CI. What these
/// tests pin is the deterministic surface:
///
/// - Error taxonomy is stable + actionable.
/// - Invalid inputs are rejected before the Keychain is touched.
/// - `exists(service:label:)` returns `false` for unused
///   `(service, label)` without prompting.
/// - Service namespaces are distinct — no collision between
///   break-glass keys and operator-identity keys even when
///   the label is the same.
@Suite("P256KeyStore", .tags(.security, .cryptography))
struct P256KeyStoreTests {

    @Test("Empty label rejected on SEP load")
    func emptyLabelOnSEP() async {
        await #expect(throws: KeyStoreError.self) {
            _ = try await P256KeyStore.loadOrCreateSEP(
                service: P256KeyStore.Service.breakGlass,
                label: ""
            )
        }
    }

    @Test("Empty label rejected on publicKey")
    func emptyLabelOnPublicKey() {
        #expect(throws: KeyStoreError.self) {
            _ = try P256KeyStore.publicKey(
                service: P256KeyStore.Service.breakGlass, label: ""
            )
        }
    }

    @Test("Empty label rejected on delete")
    func emptyLabelOnDelete() {
        #expect(throws: KeyStoreError.self) {
            try P256KeyStore.delete(service: P256KeyStore.Service.breakGlass, label: "")
        }
    }

    @Test("Presence gating without authenticationPrompt is rejected")
    func presenceGatedRequiresPrompt() async {
        await #expect(throws: KeyStoreError.self) {
            _ = try await P256KeyStore.loadOrCreateSEP(
                service: P256KeyStore.Service.breakGlass,
                label: "test-\(UUID().uuidString)",
                presenceGated: true,
                authenticationPrompt: nil
            )
        }
    }

    @Test("exists returns false for an unused service/label without prompting")
    func existsForUnused() {
        let label = "spooktacular-test-\(UUID().uuidString)"
        #expect(P256KeyStore.exists(service: P256KeyStore.Service.breakGlass, label: label) == false)
        #expect(P256KeyStore.exists(service: P256KeyStore.Service.operatorIdentity, label: label) == false)
        #expect(P256KeyStore.exists(service: P256KeyStore.Service.hostIdentity, label: label) == false)
        #expect(P256KeyStore.exists(service: P256KeyStore.Service.merkleAudit, label: label) == false)
        #expect(P256KeyStore.exists(service: P256KeyStore.Service.oidcIssuer, label: label) == false)
    }

    @Test("Service namespaces are all distinct")
    func serviceNamespacesDistinct() {
        let all = [
            P256KeyStore.Service.breakGlass,
            P256KeyStore.Service.operatorIdentity,
            P256KeyStore.Service.hostIdentity,
            P256KeyStore.Service.merkleAudit,
            P256KeyStore.Service.oidcIssuer,
        ]
        #expect(Set(all).count == all.count,
                "Every service namespace must be unique so a reviewer can enumerate each purpose distinctly")
    }

    @Test("All service tags share the com.spooktacular. prefix")
    func servicePrefix() {
        let all = [
            P256KeyStore.Service.breakGlass,
            P256KeyStore.Service.operatorIdentity,
            P256KeyStore.Service.hostIdentity,
            P256KeyStore.Service.merkleAudit,
            P256KeyStore.Service.oidcIssuer,
        ]
        for service in all {
            #expect(service.hasPrefix("com.spooktacular."),
                    "\(service) should be namespaced under com.spooktacular.")
        }
    }

    @Test("Error taxonomy provides actionable recovery guidance")
    func errorMessages() {
        let notFound = KeyStoreError.notFound(
            service: P256KeyStore.Service.breakGlass, label: "bogus"
        )
        #expect(notFound.errorDescription?.contains("bogus") == true)
        #expect(notFound.recoverySuggestion?.contains("keygen") == true)

        let declined = KeyStoreError.userDeclined
        #expect(declined.errorDescription?.contains("cancelled") == true
             || declined.errorDescription?.contains("failed") == true)

        let noSEP = KeyStoreError.secureEnclaveUnavailable(
            underlying: NSError(domain: "test", code: 0)
        )
        #expect(noSEP.errorDescription?.contains("Secure Enclave") == true)

        let badPerms = KeyStoreError.softwareKeyPermissionsTooOpen(
            path: "/tmp/key.pem", mode: 0o644
        )
        #expect(badPerms.errorDescription?.contains("0644") == true)
        #expect(badPerms.recoverySuggestion?.contains("chmod 600") == true)
    }

    // MARK: - Software fallback (actually exercises the filesystem)

    @Test("Software key creation and reload round-trip preserves the signing key")
    func softwareKeyRoundTrip() throws {
        let tmpDir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "p256keystore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appending(path: "signing.pem").path

        // First call creates.
        let first = try P256KeyStore.loadOrCreateSoftware(at: keyPath)

        // Second call reloads the same key.
        let second = try P256KeyStore.loadOrCreateSoftware(at: keyPath)

        // Same key → same public key.
        #expect(first.publicKey.pemRepresentation == second.publicKey.pemRepresentation,
                "Reload must reconstruct the same key")
    }

    @Test("Software key file is created at mode 0600")
    func softwareKeyCreatedAt0600() throws {
        let tmpDir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "p256keystore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appending(path: "signing.pem").path
        _ = try P256KeyStore.loadOrCreateSoftware(at: keyPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: keyPath)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        #expect(mode == 0o600, "Software key file must be 0600; got 0\(String(mode, radix: 8))")
    }
}
