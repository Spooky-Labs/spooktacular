import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("ProvisioningSignal", .tags(.infrastructure))
struct ProvisioningSignalTests {

    @Test("encodes to a five-byte frame beginning with the marker")
    func encodesFrame() {
        let data = ProvisioningSignal.encode(exitCode: 0)
        #expect(data.count == 5)
        #expect(data.first == 0x53)  // 'S'
    }

    @Test("round-trips exit codes", arguments: [Int32(0), 1, 42, 127, -1])
    func roundTrip(code: Int32) throws {
        let data = ProvisioningSignal.encode(exitCode: code)
        let decoded = try #require(ProvisioningSignal.decode(data))
        #expect(decoded.exitCode == code)
    }

    @Test("rejects frames that are truncated, overlong, or misbranded")
    func rejectsBadFrames() {
        #expect(ProvisioningSignal.decode(Data()) == nil)
        #expect(ProvisioningSignal.decode(Data([0x53, 0x00])) == nil)
        #expect(ProvisioningSignal.decode(Data([0x53, 0, 0, 0, 0, 0])) == nil)
        #expect(ProvisioningSignal.decode(Data([0x00, 0x00, 0x00, 0x00, 0x00])) == nil)
    }

    @Test("succeeded reflects a zero exit code")
    func succeeded() {
        #expect(ProvisioningSignal(exitCode: 0).succeeded)
        #expect(!ProvisioningSignal(exitCode: 1).succeeded)
    }

    @MainActor
    @Test("the readiness port does not collide with the agent event listener")
    func distinctPort() {
        // AgentEventListener keeps a single active connection for the
        // Guest Tools event stream; a second client on its port would
        // fight it, so readiness gets its own.
        #expect(ProvisioningSignalListener.listenerPort != AgentEventListener.listenerPort)
    }
}
