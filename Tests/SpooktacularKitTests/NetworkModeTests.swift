import Testing
import Foundation
@testable import SpooktacularKit

@Suite("NetworkMode")
struct NetworkModeTests {

    // MARK: - Codable Serialization

    @Test("nat serializes to 'nat'")
    func natSerialization() throws {
        let data = try VirtualMachineBundle.encoder.encode(NetworkMode.nat)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("nat"))

        let decoded = try VirtualMachineBundle.decoder.decode(NetworkMode.self, from: data)
        #expect(decoded == .nat)
    }

    @Test("bridged serializes with interface name")
    func bridgedSerialization() throws {
        let mode = NetworkMode.bridged(interface: "en0")
        let data = try VirtualMachineBundle.encoder.encode(mode)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("en0"))

        let decoded = try VirtualMachineBundle.decoder.decode(NetworkMode.self, from: data)
        #expect(decoded == .bridged(interface: "en0"))
    }

    @Test("isolated serializes to 'isolated'")
    func isolatedSerialization() throws {
        let data = try VirtualMachineBundle.encoder.encode(NetworkMode.isolated)
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("isolated"))

        let decoded = try VirtualMachineBundle.decoder.decode(NetworkMode.self, from: data)
        #expect(decoded == .isolated)
    }

    // MARK: - Equatable

    @Test("Same modes are equal")
    func equality() {
        #expect(NetworkMode.nat == NetworkMode.nat)
        #expect(NetworkMode.isolated == NetworkMode.isolated)
        #expect(NetworkMode.bridged(interface: "en0") == NetworkMode.bridged(interface: "en0"))
    }

    @Test("Different modes are not equal")
    func inequality() {
        #expect(NetworkMode.nat != NetworkMode.isolated)
        #expect(NetworkMode.bridged(interface: "en0") != NetworkMode.bridged(interface: "en1"))
        #expect(NetworkMode.nat != NetworkMode.bridged(interface: "en0"))
    }

    // MARK: - Hashable

    @Test("All modes are hashable and usable as Set elements")
    func hashable() {
        let modes: Set<NetworkMode> = [.nat, .isolated, .bridged(interface: "en0")]
        #expect(modes.count == 3)
        #expect(modes.contains(.nat))
        #expect(modes.contains(.isolated))
        #expect(modes.contains(.bridged(interface: "en0")))
    }

    // MARK: - init(serialized:)

    @Test("Parses 'nat' from serialized string")
    func serializedNat() {
        #expect(NetworkMode(serialized: "nat") == .nat)
    }

    @Test("Parses 'isolated' from serialized string")
    func serializedIsolated() {
        #expect(NetworkMode(serialized: "isolated") == .isolated)
    }

    @Test("Parses 'bridged:en0' from serialized string")
    func serializedBridged() {
        #expect(NetworkMode(serialized: "bridged:en0") == .bridged(interface: "en0"))
    }

    @Test("Returns nil for unknown serialized string")
    func serializedUnknown() {
        #expect(NetworkMode(serialized: "host-only") == nil)
        #expect(NetworkMode(serialized: "") == nil)
    }

    @Test("bridged serialized includes interface name")
    func bridgedSerializedFormat() {
        #expect(NetworkMode.bridged(interface: "en1").serialized == "bridged:en1")
    }

    // MARK: - Serialized round-trip

    @Test(
        "serialized property round-trips through init(serialized:)",
        arguments: [
            NetworkMode.nat,
            .isolated,
            .bridged(interface: "en0"),
            .bridged(interface: "en1"),
        ]
    )
    func serializedRoundTrip(mode: NetworkMode) {
        let result = NetworkMode(serialized: mode.serialized)
        #expect(result == mode)
    }

    // MARK: - Codable encodes as plain string

    @Test("Encodes nat as a plain JSON string")
    func encodesNatAsString() throws {
        let data = try JSONEncoder().encode(NetworkMode.nat)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"nat\"")
    }

    @Test("Encodes isolated as a plain JSON string")
    func encodesIsolatedAsString() throws {
        let data = try JSONEncoder().encode(NetworkMode.isolated)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"isolated\"")
    }

    @Test("Encodes bridged as a plain JSON string")
    func encodesBridgedAsString() throws {
        let data = try JSONEncoder().encode(NetworkMode.bridged(interface: "en0"))
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "\"bridged:en0\"")
    }

    // MARK: - Backward compatibility with old keyed format

    @Test("Decodes old keyed format for nat")
    func decodesOldNat() throws {
        let json = Data("{\"nat\":{}}".utf8)
        let decoded = try JSONDecoder().decode(NetworkMode.self, from: json)
        #expect(decoded == .nat)
    }

    @Test("Decodes old keyed format for isolated")
    func decodesOldIsolated() throws {
        let json = Data("{\"isolated\":{}}".utf8)
        let decoded = try JSONDecoder().decode(NetworkMode.self, from: json)
        #expect(decoded == .isolated)
    }

    @Test("Decodes old keyed format for bridged")
    func decodesOldBridged() throws {
        let json = Data("{\"bridged\":{\"interface\":\"en0\"}}".utf8)
        let decoded = try JSONDecoder().decode(NetworkMode.self, from: json)
        #expect(decoded == .bridged(interface: "en0"))
    }
}
