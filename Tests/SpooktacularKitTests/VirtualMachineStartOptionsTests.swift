import Testing
@testable import SpooktacularInfrastructureApple
import SpooktacularCore

@Suite("VirtualMachine start provisioning options")
@MainActor
struct VirtualMachineStartOptionsTests {
    @available(macOS 27, *)
    @Test("makeStartOptions carries the provisioning account")
    func buildsOptions() throws {
        let spec = GuestProvisioningSpec(fullName: "R", username: "runner", password: "abcdEFGH1234")
        let opts = try VirtualMachine.makeStartOptions(recovery: false, provisioning: spec)
        #expect(opts.guestProvisioningOptions?.username == "runner")
    }

    @Test("makeStartOptions with nil provisioning is a plain start")
    func nilProvisioning() throws {
        let opts = try VirtualMachine.makeStartOptions(recovery: true, provisioning: nil)
        #expect(opts.startUpFromMacOSRecovery == true)
    }
}
