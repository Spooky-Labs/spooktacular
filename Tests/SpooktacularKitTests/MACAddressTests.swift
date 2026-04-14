import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("MACAddress")
struct MACAddressTests {

    // MARK: - Initialization

    @Test("Valid lowercase MAC address")
    func validLowercase() {
        let mac = MACAddress("aa:bb:cc:dd:ee:ff")
        #expect(mac != nil)
        #expect(mac?.rawValue == "aa:bb:cc:dd:ee:ff")
    }

    @Test("Valid uppercase MAC address is normalized to lowercase")
    func validUppercase() {
        let mac = MACAddress("AA:BB:CC:DD:EE:FF")
        #expect(mac != nil)
        #expect(mac?.rawValue == "aa:bb:cc:dd:ee:ff")
    }

    @Test("Valid mixed-case MAC address is normalized to lowercase")
    func validMixedCase() {
        let mac = MACAddress("Aa:Bb:Cc:Dd:Ee:Ff")
        #expect(mac != nil)
        #expect(mac?.rawValue == "aa:bb:cc:dd:ee:ff")
    }

    @Test("Invalid MAC address returns nil")
    func invalidFormat() {
        #expect(MACAddress("not-a-mac") == nil)
        #expect(MACAddress("") == nil)
        #expect(MACAddress("aa:bb:cc:dd:ee") == nil)
        #expect(MACAddress("aa:bb:cc:dd:ee:ff:00") == nil)
        #expect(MACAddress("aabb.ccdd.eeff") == nil)
        #expect(MACAddress("aa-bb-cc-dd-ee-ff") == nil)
        #expect(MACAddress("gg:hh:ii:jj:kk:ll") == nil)
        #expect(MACAddress("aa:bb:cc:dd:ee:f") == nil)
    }

    // MARK: - Generation

    @Test("Generated MAC address has valid format")
    func generatedFormat() {
        let mac = MACAddress.generate()
        let parts = mac.rawValue.split(separator: ":")
        #expect(parts.count == 6)
        for part in parts {
            #expect(part.count == 2)
            #expect(part.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("Generated MAC address has locally administered bit set")
    func generatedLocallyAdministered() throws {
        let mac = MACAddress.generate()
        let firstOctet = try #require(UInt8(mac.rawValue.prefix(2), radix: 16))
        #expect(firstOctet & 0x02 == 0x02)
    }

    @Test("Generated MAC address has multicast bit cleared")
    func generatedUnicast() throws {
        let mac = MACAddress.generate()
        let firstOctet = try #require(UInt8(mac.rawValue.prefix(2), radix: 16))
        #expect(firstOctet & 0x01 == 0x00)
    }

    @Test("Generated MAC addresses are unique")
    func generatedUniqueness() {
        let addresses = (0..<100).map { _ in MACAddress.generate() }
        let unique = Set(addresses)
        #expect(unique.count == 100)
    }

    // MARK: - Codable

    @Test("Round-trips through JSON as a plain string")
    func jsonRoundTrip() throws {
        let mac = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
        let data = try JSONEncoder().encode(mac)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "\"aa:bb:cc:dd:ee:ff\"")

        let decoded = try JSONDecoder().decode(MACAddress.self, from: data)
        #expect(decoded == mac)
    }

    @Test("Decoding invalid MAC address throws")
    func decodingInvalidThrows() {
        let json = Data("\"not-a-mac\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MACAddress.self, from: json)
        }
    }

    @Test("Encodes as a single JSON string, not an object")
    func encodesAsString() throws {
        let mac = try #require(MACAddress("02:ab:cd:ef:01:23"))
        let data = try JSONEncoder().encode(mac)
        let json = try #require(String(data: data, encoding: .utf8))
        // Must be a simple quoted string, not {"rawValue":"..."}
        #expect(json.hasPrefix("\""))
        #expect(!json.contains("rawValue"))
    }

    // MARK: - Equatable & Hashable

    @Test("Two MAC addresses with same value are equal")
    func equality() {
        let a = MACAddress("aa:bb:cc:dd:ee:ff")
        let b = MACAddress("AA:BB:CC:DD:EE:FF")
        #expect(a == b)
    }

    @Test("Two MAC addresses with different values are not equal")
    func inequality() {
        let a = MACAddress("aa:bb:cc:dd:ee:ff")
        let b = MACAddress("11:22:33:44:55:66")
        #expect(a != b)
    }

    @Test("MAC addresses are usable as Set elements")
    func hashable() {
        let a = MACAddress("aa:bb:cc:dd:ee:ff")!
        let b = MACAddress("11:22:33:44:55:66")!
        let c = MACAddress("AA:BB:CC:DD:EE:FF")! // same as a
        let set: Set<MACAddress> = [a, b, c]
        #expect(set.count == 2)
    }

    // MARK: - CustomStringConvertible

    @Test("Description returns rawValue")
    func description() {
        let mac = MACAddress("aa:bb:cc:dd:ee:ff")!
        #expect(mac.description == "aa:bb:cc:dd:ee:ff")
        #expect("\(mac)" == "aa:bb:cc:dd:ee:ff")
    }

    // MARK: - Integration with VirtualMachineSpecification

    @Test("VirtualMachineSpecification round-trips MACAddress through JSON")
    func specRoundTrip() throws {
        let mac = try #require(MACAddress("02:ab:cd:ef:01:23"))
        let spec = VirtualMachineSpecification(macAddress: mac)
        let data = try VirtualMachineBundle.encoder.encode(spec)
        let decoded = try VirtualMachineBundle.decoder.decode(
            VirtualMachineSpecification.self, from: data
        )
        #expect(decoded.macAddress == mac)
    }

    @Test("VirtualMachineSpecification with nil MACAddress round-trips")
    func specNilRoundTrip() throws {
        let spec = VirtualMachineSpecification()
        let data = try VirtualMachineBundle.encoder.encode(spec)
        let decoded = try VirtualMachineBundle.decoder.decode(
            VirtualMachineSpecification.self, from: data
        )
        #expect(decoded.macAddress == nil)
    }
}
