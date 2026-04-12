import Testing
import Foundation
@testable import SpooktacularKit

@Suite("VsockProvisioner")
struct VsockProvisionerTests {

    // MARK: - Agent Port

    @Test("Agent port is 9470")
    func agentPortValue() {
        #expect(VsockProvisioner.agentPort == 9470)
    }

    @Test("Agent port is within the valid vsock range")
    func agentPortRange() {
        // vsock ports are UInt32; usable range is above 1023.
        #expect(VsockProvisioner.agentPort > 1023)
        #expect(VsockProvisioner.agentPort < UInt32.max)
    }

    // MARK: - VsockProvisionerError Descriptions

    @Test("noSocketDevice error has a description")
    func noSocketDeviceDescription() {
        let error = VsockProvisionerError.noSocketDevice
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
        #expect(error.localizedDescription.contains("VirtIO socket"))
    }

    @Test("agentNotResponding error has a description")
    func agentNotRespondingDescription() {
        let error = VsockProvisionerError.agentNotResponding
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
        #expect(error.localizedDescription.contains("agent"))
    }

    @Test("scriptFailed error includes exit code")
    func scriptFailedDescription() {
        let error = VsockProvisionerError.scriptFailed(exitCode: 42)
        #expect(error.errorDescription != nil)
        #expect(error.localizedDescription.contains("42"))
    }

    // MARK: - VsockProvisionerError Recovery Suggestions

    @Test("noSocketDevice error has a recovery suggestion")
    func noSocketDeviceRecovery() {
        let error = VsockProvisionerError.noSocketDevice
        #expect(error.recoverySuggestion != nil)
        #expect(!error.recoverySuggestion!.isEmpty)
    }

    @Test("agentNotResponding error suggests SSH fallback")
    func agentNotRespondingRecovery() {
        let error = VsockProvisionerError.agentNotResponding
        let recovery = error.recoverySuggestion
        #expect(recovery != nil)
        #expect(recovery!.contains("ssh") || recovery!.contains("SSH"))
    }

    @Test("scriptFailed error has a recovery suggestion")
    func scriptFailedRecovery() {
        let error = VsockProvisionerError.scriptFailed(exitCode: 1)
        #expect(error.recoverySuggestion != nil)
        #expect(!error.recoverySuggestion!.isEmpty)
    }

    // MARK: - VsockProvisionerError Equatable

    @Test("VsockProvisionerError is equatable")
    func errorEquatable() {
        #expect(
            VsockProvisionerError.noSocketDevice
            == VsockProvisionerError.noSocketDevice
        )
        #expect(
            VsockProvisionerError.agentNotResponding
            == VsockProvisionerError.agentNotResponding
        )
        #expect(
            VsockProvisionerError.scriptFailed(exitCode: 1)
            == VsockProvisionerError.scriptFailed(exitCode: 1)
        )
        #expect(
            VsockProvisionerError.scriptFailed(exitCode: 1)
            != VsockProvisionerError.scriptFailed(exitCode: 2)
        )
        #expect(
            VsockProvisionerError.noSocketDevice
            != VsockProvisionerError.agentNotResponding
        )
    }

    // MARK: - All Cases Have Descriptions

    @Test("Every VsockProvisionerError case has a non-empty description")
    func allCasesDescribed() {
        let cases: [VsockProvisionerError] = [
            .noSocketDevice,
            .agentNotResponding,
            .scriptFailed(exitCode: 1),
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("Every VsockProvisionerError case has a recovery suggestion")
    func allCasesHaveRecovery() {
        let cases: [VsockProvisionerError] = [
            .noSocketDevice,
            .agentNotResponding,
            .scriptFailed(exitCode: 1),
        ]
        for error in cases {
            #expect(error.recoverySuggestion != nil)
            #expect(!error.recoverySuggestion!.isEmpty)
        }
    }
}
