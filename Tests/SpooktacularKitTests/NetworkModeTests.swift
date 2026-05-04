import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

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

    // MARK: - Throwing init

    @Test("NetworkMode(serialized:) parses accepted strings",
          arguments: [
              ("nat", NetworkMode.nat),
              ("isolated", NetworkMode.isolated),
              ("bridged:en0", NetworkMode.bridged(interface: "en0")),
              ("bridged:bridge100", NetworkMode.bridged(interface: "bridge100")),
          ] as [(String, NetworkMode)])
    func initSerializedAccepts(input: String, expected: NetworkMode) throws {
        let parsed = try NetworkMode(serialized: input)
        #expect(parsed == expected)
    }

    @Test("NetworkMode(serialized:) throws with an actionable reason",
          arguments: [
              "host-only",    // wrong enum name
              "",             // empty
              "bridged:",     // missing interface
              "bridge:en0",   // wrong prefix
          ])
    func initSerializedThrows(input: String) {
        do {
            _ = try NetworkMode(serialized: input)
            Issue.record("Expected NetworkMode(serialized: '\(input)') to throw")
        } catch let NetworkModeError.invalidFormat(raw, reason) {
            #expect(raw == input)
            #expect(!reason.isEmpty, "Error must name the accepted forms")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
