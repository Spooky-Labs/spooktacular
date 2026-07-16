import Testing
@testable import SpooktacularCore

@Suite("GuestProvisioningSpec")
struct GuestProvisioningSpecTests {
    @Test("defaults: auto-login on, SSH off")
    func defaults() {
        let s = GuestProvisioningSpec(fullName: "Spooktacular Runner", username: "runner", password: "abcdEFGH1234")
        #expect(s.logsInAutomatically == true)
        #expect(s.enablesRemoteLogin == false)
    }

    @Test("validated rejects empty username")
    func emptyUsername() {
        let s = GuestProvisioningSpec(fullName: "R", username: "", password: "abcdEFGH1234")
        #expect(throws: GuestProvisioningError.emptyUsername) { try s.validated() }
    }

    @Test("validated rejects short password")
    func shortPassword() {
        let s = GuestProvisioningSpec(fullName: "R", username: "runner", password: "short")
        #expect(throws: GuestProvisioningError.passwordTooShort) { try s.validated() }
    }

    @Test("validated passes a well-formed spec")
    func valid() throws {
        let s = GuestProvisioningSpec(fullName: "R", username: "runner", password: "abcdEFGH1234")
        #expect(try s.validated() == s)
    }
}
