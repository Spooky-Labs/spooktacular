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
}
