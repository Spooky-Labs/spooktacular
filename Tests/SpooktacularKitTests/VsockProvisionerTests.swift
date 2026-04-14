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

    @Test("agentNotResponding error suggests SSH fallback")
    func agentNotRespondingRecovery() {
        let error = VsockProvisionerError.agentNotResponding
        let recovery = error.recoverySuggestion
        #expect(recovery != nil)
        #expect(recovery!.contains("ssh") || recovery!.contains("SSH"))
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

    // MARK: - Wire Protocol

    @Test("Frame encodes length as 4-byte big-endian prefix")
    func frameEncoding() {
        let script = "echo hello"
        let frame = VsockProvisioner.encodeFrame(script)

        // First 4 bytes are the length prefix.
        let lengthData = frame.prefix(4)
        let length = lengthData.withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        #expect(length == UInt32(script.utf8.count))

        // Remaining bytes are the script content.
        let content = frame.dropFirst(4)
        #expect(String(data: Data(content), encoding: .utf8) == script)

        // Total frame size is 4 + script length.
        #expect(frame.count == 4 + script.utf8.count)
    }

    @Test("Frame encodes empty script with zero-length prefix")
    func frameEncodesEmptyScript() {
        let frame = VsockProvisioner.encodeFrame("")
        #expect(frame.count == 4)

        let length = frame.withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        }
        #expect(length == 0)
    }

    @Test("Exit code decodes from 4-byte big-endian response")
    func exitCodeDecoding() {
        // Encode exit code 0.
        var zero: UInt32 = UInt32(0).bigEndian
        let zeroData = Data(bytes: &zero, count: 4)
        #expect(VsockProvisioner.decodeExitCode(from: zeroData) == 0)

        // Encode exit code 42.
        var fortyTwo: UInt32 = UInt32(42).bigEndian
        let fortyTwoData = Data(bytes: &fortyTwo, count: 4)
        #expect(VsockProvisioner.decodeExitCode(from: fortyTwoData) == 42)

        // Encode exit code 1.
        var one: UInt32 = UInt32(1).bigEndian
        let oneData = Data(bytes: &one, count: 4)
        #expect(VsockProvisioner.decodeExitCode(from: oneData) == 1)
    }

    @Test("Exit code returns nil for wrong-size data")
    func exitCodeWrongSize() {
        #expect(VsockProvisioner.decodeExitCode(from: Data()) == nil)
        #expect(VsockProvisioner.decodeExitCode(from: Data([0x00, 0x00])) == nil)
        #expect(VsockProvisioner.decodeExitCode(from: Data([0x00, 0x00, 0x00, 0x00, 0x01])) == nil)
    }

}
