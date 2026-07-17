import Testing
import Foundation
import SpooktacularInfrastructureApple

/// Exercises the real login-Keychain path of ``ProvisioningPasswordStore``
/// — store, read, overwrite, delete — end to end. Runs in-process against
/// the caller's login Keychain (the test creates and reads its own items,
/// so no interactive prompt), which is the same path `spook create` /
/// `spook start` take on a developer's Mac and the local `fastlane test`
/// gate. Every case uses a fresh UUID and cleans up via `defer` so runs
/// never collide or leave residue.
@Suite("Provisioning password store (Keychain round-trip)")
struct ProvisioningPasswordStoreTests {

    @Test("store → read → delete round-trips a real Keychain item")
    func roundTrip() throws {
        let id = UUID()
        defer { try? ProvisioningPasswordStore.deletePassword(forVM: id) }

        try ProvisioningPasswordStore.store(password: "s3cret-p@ssw0rd", forVM: id)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id) == "s3cret-p@ssw0rd")

        try ProvisioningPasswordStore.deletePassword(forVM: id)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id) == nil)
    }

    @Test("store overwrites the existing item for the same VM")
    func overwrite() throws {
        let id = UUID()
        defer { try? ProvisioningPasswordStore.deletePassword(forVM: id) }

        try ProvisioningPasswordStore.store(password: "first-password-abc", forVM: id)
        try ProvisioningPasswordStore.store(password: "second-password-xyz", forVM: id)
        #expect(try ProvisioningPasswordStore.readPassword(forVM: id) == "second-password-xyz")
    }

    @Test("reading an unknown VM returns nil, not an error")
    func absentReturnsNil() throws {
        #expect(try ProvisioningPasswordStore.readPassword(forVM: UUID()) == nil)
    }

    @Test("an empty password is rejected before it touches the Keychain")
    func rejectsEmpty() {
        #expect(throws: ProvisioningPasswordStoreError.emptyPassword) {
            try ProvisioningPasswordStore.store(password: "", forVM: UUID())
        }
    }

    @Test("deleting an absent item is a no-op, not an error")
    func idempotentDelete() throws {
        try ProvisioningPasswordStore.deletePassword(forVM: UUID())
    }
}
