import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("MACAddress", .tags(.networking))
struct MACAddressTests {

    // MARK: - Initialization

    @Suite("Initialization")
    struct Initialization {

        @Test("valid format is accepted and normalized to lowercase", arguments: [
            ("aa:bb:cc:dd:ee:ff", "aa:bb:cc:dd:ee:ff"),
            ("AA:BB:CC:DD:EE:FF", "aa:bb:cc:dd:ee:ff"),
            ("Aa:Bb:Cc:Dd:Ee:Ff", "aa:bb:cc:dd:ee:ff"),
            ("02:ab:cd:ef:01:23", "02:ab:cd:ef:01:23"),
            ("00:00:00:00:00:00", "00:00:00:00:00:00"),
            ("ff:ff:ff:ff:ff:ff", "ff:ff:ff:ff:ff:ff"),
        ] as [(String, String)])
        func validFormat(input: String, expected: String) throws {
            let mac = try #require(MACAddress(input))
            #expect(mac.rawValue == expected)
        }

        @Test("invalid format returns nil", arguments: [
            "not-a-mac",
            "",
            "aa:bb:cc:dd:ee",
            "aa:bb:cc:dd:ee:ff:00",
            "aabb.ccdd.eeff",
            "aa-bb-cc-dd-ee-ff",
            "gg:hh:ii:jj:kk:ll",
            "aa:bb:cc:dd:ee:f",
            "aa:bb:cc:dd:ee:fff",
            " aa:bb:cc:dd:ee:ff",
            "aa:bb:cc:dd:ee:ff ",
        ])
        func invalidFormat(input: String) {
            #expect(MACAddress(input) == nil)
        }
    }

    // MARK: - Generation

    @Suite("Generation")
    struct Generation {

        @Test("generated address has valid six-octet hex format")
        func generatedFormat() {
            let mac = MACAddress.generate()
            let parts = mac.rawValue.split(separator: ":")
            #expect(parts.count == 6)
            for part in parts {
                #expect(part.count == 2)
                #expect(part.allSatisfy { $0.isHexDigit })
            }
        }

        @Test("generated address has locally administered bit set")
        func generatedLocallyAdministered() throws {
            let mac = MACAddress.generate()
            let firstOctet = try #require(UInt8(mac.rawValue.prefix(2), radix: 16))
            #expect(firstOctet & 0x02 == 0x02)
        }

        @Test("generated address has multicast bit cleared (unicast)")
        func generatedUnicast() throws {
            let mac = MACAddress.generate()
            let firstOctet = try #require(UInt8(mac.rawValue.prefix(2), radix: 16))
            #expect(firstOctet & 0x01 == 0x00)
        }

        @Test("100 generated addresses are all unique (CSPRNG quality)")
        func generatedUniqueness() {
            let addresses = (0..<100).map { _ in MACAddress.generate() }
            let unique = Set(addresses)
            #expect(unique.count == 100)
        }
    }

    // MARK: - Codable

    @Suite("Codable")
    struct CodableTests {

        @Test("round-trips through JSON as a plain string")
        func jsonRoundTrip() throws {
            let mac = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
            let data = try JSONEncoder().encode(mac)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json == "\"aa:bb:cc:dd:ee:ff\"")

            let decoded = try JSONDecoder().decode(MACAddress.self, from: data)
            #expect(decoded == mac)
        }

        @Test("decoding invalid MAC address throws DecodingError")
        func decodingInvalidThrows() {
            let json = Data("\"not-a-mac\"".utf8)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(MACAddress.self, from: json)
            }
        }

        @Test("encodes as a single JSON string, not an object with rawValue key")
        func encodesAsString() throws {
            let mac = try #require(MACAddress("02:ab:cd:ef:01:23"))
            let data = try JSONEncoder().encode(mac)
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(json.hasPrefix("\""))
            #expect(!json.contains("rawValue"))
        }
    }

    // MARK: - Equatable & Hashable

    @Suite("Equatable & Hashable")
    struct EquatableHashable {

        @Test("case-insensitive inputs produce equal addresses")
        func equality() {
            let a = MACAddress("aa:bb:cc:dd:ee:ff")
            let b = MACAddress("AA:BB:CC:DD:EE:FF")
            #expect(a == b)
        }

        @Test("different values are not equal")
        func inequality() {
            let a = MACAddress("aa:bb:cc:dd:ee:ff")
            let b = MACAddress("11:22:33:44:55:66")
            #expect(a != b)
        }

        @Test("normalized duplicates collapse in a Set")
        func hashable() throws {
            let a = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
            let b = try #require(MACAddress("11:22:33:44:55:66"))
            let c = try #require(MACAddress("AA:BB:CC:DD:EE:FF"))
            let set: Set<MACAddress> = [a, b, c]
            #expect(set.count == 2)
        }
    }

    // MARK: - CustomStringConvertible

    @Test("description returns rawValue")
    func description() throws {
        let mac = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
        #expect(mac.description == "aa:bb:cc:dd:ee:ff")
        #expect("\(mac)" == "aa:bb:cc:dd:ee:ff")
    }

    // MARK: - Integration with VirtualMachineSpecification

    @Suite("VirtualMachineSpecification integration")
    struct SpecIntegration {

        @Test("round-trips MACAddress through VirtualMachineBundle JSON")
        func specRoundTrip() throws {
            let mac = try #require(MACAddress("02:ab:cd:ef:01:23"))
            let spec = VirtualMachineSpecification(macAddress: mac)
            let data = try VirtualMachineBundle.encoder.encode(spec)
            let decoded = try VirtualMachineBundle.decoder.decode(
                VirtualMachineSpecification.self, from: data
            )
            #expect(decoded.macAddress == mac)
        }

        @Test("nil MACAddress round-trips through VirtualMachineBundle JSON")
        func specNilRoundTrip() throws {
            let spec = VirtualMachineSpecification()
            let data = try VirtualMachineBundle.encoder.encode(spec)
            let decoded = try VirtualMachineBundle.decoder.decode(
                VirtualMachineSpecification.self, from: data
            )
            #expect(decoded.macAddress == nil)
        }
    }
}
