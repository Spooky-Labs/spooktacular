import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

/// Exercises the store/read/overwrite/delete logic of
/// ``ProvisioningPasswordStore`` end to end against a **real** Keychain.
///
/// Production writes the **System** keychain (root-only), which `swift
/// test` can't reach unprivileged — so these round-trips use the internal
/// `.login` target, verifying the SecItem query logic and semantics
/// in-process (the test creates and reads its own items, so no interactive
/// prompt). The System-keychain path itself is exercised by the
/// on-hardware `spook create --remote-desktop` smoke test under `sudo`.
/// Every case uses a fresh UUID and cleans up via `defer`.
@Suite("Provisioning password store (Keychain round-trip)")
struct ProvisioningPasswordStoreTests {

    @Test("store → read → delete round-trips a real Keychain item")
    func roundTrip() throws {
        let id = UUID()
        defer { try? ProvisioningPasswordStore.deletePassword(forVM: id, in: .login) }

        try ProvisioningPasswordStore.store(password: "s3cret-p@ssw0rd", forVM: id, in: .login)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id, in: .login) == "s3cret-p@ssw0rd")

        try ProvisioningPasswordStore.deletePassword(forVM: id, in: .login)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id, in: .login) == nil)
    }

    @Test("store overwrites the existing item for the same VM")
    func overwrite() throws {
        let id = UUID()
        defer { try? ProvisioningPasswordStore.deletePassword(forVM: id, in: .login) }

        try ProvisioningPasswordStore.store(password: "first-password-abc", forVM: id, in: .login)
        try ProvisioningPasswordStore.store(password: "second-password-xyz", forVM: id, in: .login)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id, in: .login) == "second-password-xyz")
    }

    @Test("reading an unknown VM returns nil, not an error")
    func absentReturnsNil() throws {
        #expect(try ProvisioningPasswordStore.readPassword(forVM: UUID(), in: .login) == nil)
    }

    @Test("an empty password is rejected before it touches the Keychain")
    func rejectsEmpty() {
        #expect(throws: ProvisioningPasswordStoreError.emptyPassword) {
            try ProvisioningPasswordStore.store(password: "", forVM: UUID(), in: .login)
        }
    }

    @Test("deleting an absent item is a no-op, not an error")
    func idempotentDelete() throws {
        try ProvisioningPasswordStore.deletePassword(forVM: UUID(), in: .login)
    }
}
