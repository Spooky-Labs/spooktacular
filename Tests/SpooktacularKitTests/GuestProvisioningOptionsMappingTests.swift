import Testing
import Foundation
@testable import SpooktacularInfrastructureApple
import SpooktacularCore

@Suite("GuestProvisioningOptionsMapping")
struct GuestProvisioningOptionsMappingTests {
    @Test("generated password is long and non-trivial")
    func password() {
        let p = EphemeralCredential.generatePassword()
        #expect(p.count >= 24)
        #expect(p != EphemeralCredential.generatePassword())  // effectively never equal
    }

    @available(macOS 27, *)
    @Test("spec maps onto VZMacGuestProvisioningOptions fields")
    func mapping() {
        let spec = GuestProvisioningSpec(
            fullName: "Spooktacular Runner", username: "runner",
            password: "abcdEFGH1234", logsInAutomatically: true, enablesRemoteLogin: false
        )
        let opts = makeGuestProvisioningOptions(from: spec)
        #expect(opts.username == "runner")
        #expect(opts.fullName == "Spooktacular Runner")
        #expect(opts.password == "abcdEFGH1234")
        #expect(opts.logsInAutomatically == true)
        #expect(opts.enablesRemoteLogin == false)
    }
}
