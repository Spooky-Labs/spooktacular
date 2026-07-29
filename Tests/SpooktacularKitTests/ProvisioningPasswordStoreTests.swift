import Testing
import Foundation
import Security
@testable import SpooktacularInfrastructureApple

/// Exercises the store/read/overwrite/delete logic of
/// ``ProvisioningPasswordStore`` end to end against a **real** Keychain.
///
/// Production writes the **System** keychain (root-only), which `swift
/// test` can't reach unprivileged — so these round-trips run against a
/// throwaway ``TemporaryKeychain`` created per test, verifying the
/// SecItem query logic and semantics in-process. The System-keychain
/// path itself is exercised by the on-hardware
/// `spook create --remote-desktop` smoke test under `sudo`.
///
/// Using a dedicated keychain rather than the developer's login keychain
/// is what makes these tests deterministic under `swift test --parallel`:
/// hundreds of tests share one process, several touch the keychain, and a
/// delete-then-add against that shared store intermittently observed a
/// stale view and failed with `errSecDuplicateItem`.
@Suite("Provisioning password store (Keychain round-trip)")
struct ProvisioningPasswordStoreTests {

    @Test("store → read → delete round-trips a real Keychain item")
    func roundTrip() throws {
        let keychain = try TemporaryKeychain()
        let id = UUID()

        try ProvisioningPasswordStore.store(
            password: "s3cret-p@ssw0rd", forVM: id, in: keychain.target
        )
        #expect(
            try ProvisioningPasswordStore.readPassword(forVM: id, in: keychain.target)
                == "s3cret-p@ssw0rd"
        )

        try ProvisioningPasswordStore.deletePassword(forVM: id, in: keychain.target)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id, in: keychain.target) == nil)
    }

    @Test("store overwrites the existing item for the same VM")
    func overwrite() throws {
        let keychain = try TemporaryKeychain()
        let id = UUID()

        try ProvisioningPasswordStore.store(
            password: "first-password-abc", forVM: id, in: keychain.target
        )
        try ProvisioningPasswordStore.store(
            password: "second-password-xyz", forVM: id, in: keychain.target
        )
        #expect(
            try ProvisioningPasswordStore.readPassword(forVM: id, in: keychain.target)
                == "second-password-xyz"
        )
    }

    @Test("items for different VMs do not collide")
    func distinctVMs() throws {
        let keychain = try TemporaryKeychain()
        let first = UUID()
        let second = UUID()

        try ProvisioningPasswordStore.store(
            password: "first-secret", forVM: first, in: keychain.target
        )
        try ProvisioningPasswordStore.store(
            password: "second-secret", forVM: second, in: keychain.target
        )

        try ProvisioningPasswordStore.deletePassword(forVM: first, in: keychain.target)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: first, in: keychain.target) == nil)
        #expect(
            try ProvisioningPasswordStore.readPassword(forVM: second, in: keychain.target)
                == "second-secret",
            "deleting one VM's password must not disturb another's"
        )
    }

    @Test("reading an unknown VM returns nil, not an error")
    func absentReturnsNil() throws {
        let keychain = try TemporaryKeychain()
        #expect(try ProvisioningPasswordStore.readPassword(forVM: UUID(), in: keychain.target) == nil)
    }

    @Test("an empty password is rejected before it touches the Keychain")
    func rejectsEmpty() throws {
        let keychain = try TemporaryKeychain()
        #expect(throws: ProvisioningPasswordStoreError.emptyPassword) {
            try ProvisioningPasswordStore.store(password: "", forVM: UUID(), in: keychain.target)
        }
    }

    @Test("deleting an absent item is a no-op, not an error")
    func idempotentDelete() throws {
        let keychain = try TemporaryKeychain()
        try ProvisioningPasswordStore.deletePassword(forVM: UUID(), in: keychain.target)
    }

    @Test("a temporary keychain is invisible to the default search list")
    func isolatedFromLoginKeychain() throws {
        // The isolation guarantee this suite depends on: an item written
        // to the throwaway keychain must not be findable through an
        // unscoped query, or these tests would still be racing every
        // other keychain-touching test in the process.
        let keychain = try TemporaryKeychain()
        let id = UUID()
        try ProvisioningPasswordStore.store(
            password: "isolated-secret", forVM: id, in: keychain.target
        )

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        #expect(
            status == errSecItemNotFound,
            "an unscoped lookup must not see the temporary keychain's items"
        )
    }
}
