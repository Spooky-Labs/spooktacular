import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("VsockProvisioner", .tags(.networking))
struct VsockProvisionerTests {

    // MARK: - Port Constants

    @Suite("Port constants")
    struct PortConstants {

        @Test("agent port is 9470")
        func agentPortValue() {
            #expect(VsockProvisioner.agentPort == 9470)
        }

        @Test("runner port is 9471")
        func runnerPortValue() {
            #expect(VsockProvisioner.runnerPort == 9471)
        }

        @Test("break-glass port is 9472")
        func breakGlassPortValue() {
            #expect(VsockProvisioner.breakGlassPort == 9472)
        }
    }

    // MARK: - VsockProvisionerError

    @Suite("VsockProvisionerError")
    struct ErrorTests {

        @Test("agentNotResponding recovery suggests SSH fallback")
        func agentNotRespondingRecovery() throws {
            let error = VsockProvisionerError.agentNotResponding
            let recovery = try #require(error.recoverySuggestion)
            #expect(recovery.contains("ssh") || recovery.contains("SSH"))
        }

        @Test("equatable: same values are equal", arguments: [
            (VsockProvisionerError.noSocketDevice,
             VsockProvisionerError.noSocketDevice, true),
            (VsockProvisionerError.agentNotResponding,
             VsockProvisionerError.agentNotResponding, true),
            (VsockProvisionerError.scriptFailed(exitCode: 1),
             VsockProvisionerError.scriptFailed(exitCode: 1), true),
            (VsockProvisionerError.scriptFailed(exitCode: 1),
             VsockProvisionerError.scriptFailed(exitCode: 2), false),
            (VsockProvisionerError.noSocketDevice,
             VsockProvisionerError.agentNotResponding, false),
        ] as [(VsockProvisionerError, VsockProvisionerError, Bool)])
        func equatable(
            lhs: VsockProvisionerError,
            rhs: VsockProvisionerError,
            shouldBeEqual: Bool
        ) {
            #expect((lhs == rhs) == shouldBeEqual)
        }
    }

}
