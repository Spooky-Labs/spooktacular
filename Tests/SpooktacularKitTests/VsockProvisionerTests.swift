import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

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

    // MARK: - Wire Protocol

    @Suite("Wire protocol")
    struct WireProtocol {

        @Test("frame encodes length as 4-byte big-endian prefix")
        func frameEncoding() {
            let script = "echo hello"
            let frame = VsockProvisioner.encodeFrame(script)

            let lengthData = frame.prefix(4)
            let length = lengthData.withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            #expect(length == UInt32(script.utf8.count))

            let content = frame.dropFirst(4)
            #expect(String(data: Data(content), encoding: .utf8) == script)
            #expect(frame.count == 4 + script.utf8.count)
        }

        @Test("frame encodes empty script with zero-length prefix")
        func frameEncodesEmptyScript() {
            let frame = VsockProvisioner.encodeFrame("")
            #expect(frame.count == 4)

            let length = frame.withUnsafeBytes {
                UInt32(bigEndian: $0.load(as: UInt32.self))
            }
            #expect(length == 0)
        }

        @Test("exit code decodes from 4-byte big-endian response", arguments: [
            (UInt32(0), UInt32(0)),
            (UInt32(1), UInt32(1)),
            (UInt32(42), UInt32(42)),
        ] as [(UInt32, UInt32)])
        func exitCodeDecoding(rawValue: UInt32, expected: UInt32) throws {
            var bigEndian = rawValue.bigEndian
            let data = Data(bytes: &bigEndian, count: 4)
            let decoded = try #require(VsockProvisioner.decodeExitCode(from: data))
            #expect(decoded == expected)
        }

        @Test("exit code returns nil for wrong-size data", arguments: [
            Data(),
            Data([0x00, 0x00]),
            Data([0x00, 0x00, 0x00, 0x00, 0x01]),
        ])
        func exitCodeWrongSize(data: Data) {
            #expect(VsockProvisioner.decodeExitCode(from: data) == nil)
        }
    }
}
