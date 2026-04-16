import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("NetworkMode", .tags(.networking, .configuration))
struct NetworkModeTests {

    // MARK: - Codable Round-Trip

    @Test("network mode survives encode→decode round-trip",
          arguments: [
              NetworkMode.nat,
              NetworkMode.bridged(interface: "en0"),
              NetworkMode.isolated,
          ])
    func codableRoundTrip(mode: NetworkMode) throws {
        let data = try VirtualMachineBundle.encoder.encode(mode)
        let decoded = try VirtualMachineBundle.decoder.decode(NetworkMode.self, from: data)
        #expect(decoded == mode)
    }

    // MARK: - Equality

    @Test("same modes are equal")
    func equality() {
        #expect(NetworkMode.nat == NetworkMode.nat)
        #expect(NetworkMode.bridged(interface: "en0") == NetworkMode.bridged(interface: "en0"))
    }

    @Test("different modes are not equal")
    func inequality() {
        #expect(NetworkMode.nat != NetworkMode.isolated)
        #expect(NetworkMode.bridged(interface: "en0") != NetworkMode.bridged(interface: "en1"))
    }

    // MARK: - Serialized Format

    @Test("bridged includes interface name in serialized form")
    func bridgedIncludesInterface() throws {
        let mode = NetworkMode.bridged(interface: "en0")
        let serialized = mode.serialized
        #expect(serialized.contains("en0"))
    }

    @Test("backward-compatible deserialization from legacy format",
          arguments: ["nat", "isolated"])
    func legacyDeserialization(raw: String) throws {
        let data = Data("\"\(raw)\"".utf8)
        let decoded = try VirtualMachineBundle.decoder.decode(NetworkMode.self, from: data)
        #expect(decoded == (raw == "nat" ? .nat : .isolated))
    }
}
