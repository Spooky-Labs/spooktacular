import Testing
import Foundation
@testable import SpooktacularCore

@Suite("IconSpec", .tags(.configuration))
struct IconSpecTests {

    // MARK: - Codable round-trip

    @Suite("Codable round-trip")
    struct CodableRoundTrip {

        private static func roundTrip(_ spec: IconSpec) throws -> IconSpec {
            let data = try JSONEncoder().encode(spec)
            return try JSONDecoder().decode(IconSpec.self, from: data)
        }

        @Test(
            "All four modes round-trip through JSON",
            arguments: [
                IconSpec.cloneApp(bundleID: "com.apple.Safari"),
                IconSpec.stack(top: "gearshape.fill", bottom: "macpro.gen3"),
                IconSpec.glassFrame(symbol: "hammer.fill", tint: .blue),
                IconSpec.preset(name: "runner"),
            ]
        )
        func roundTrip(_ spec: IconSpec) throws {
            let decoded = try Self.roundTrip(spec)
            #expect(decoded == spec)
        }

        @Test("Default spec is stable across encode/decode")
        func defaultSpec() throws {
            let decoded = try Self.roundTrip(.defaultSpec)
            #expect(decoded == IconSpec.defaultSpec)
        }
    }

    // MARK: - JSON shape

    @Suite("JSON wire format")
    struct JSONShape {

        @Test("glassFrame encodes with mode, symbol, tint")
        func glassFrameShape() throws {
            let spec = IconSpec.glassFrame(symbol: "hammer.fill", tint: .purple)
            let data = try JSONEncoder().encode(spec)
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(json["mode"] as? String == "glassFrame")
            #expect(json["symbol"] as? String == "hammer.fill")
            #expect(json["tint"] as? String == "purple")
        }

        @Test("cloneApp encodes with mode + bundleID")
        func cloneAppShape() throws {
            let spec = IconSpec.cloneApp(bundleID: "com.microsoft.VSCode")
            let data = try JSONEncoder().encode(spec)
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(json["mode"] as? String == "cloneApp")
            #expect(json["bundleID"] as? String == "com.microsoft.VSCode")
        }

        @Test("stack encodes with top + bottom")
        func stackShape() throws {
            let spec = IconSpec.stack(top: "a", bottom: "b")
            let data = try JSONEncoder().encode(spec)
            let json = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(json["mode"] as? String == "stack")
            #expect(json["top"] as? String == "a")
            #expect(json["bottom"] as? String == "b")
        }

        @Test("Unknown mode causes decode to fail with a typed error")
        func unknownModeFailsDecode() {
            let payload = #"{"mode": "unicorn"}"#
            let data = Data(payload.utf8)
            #expect(throws: DecodingError.self) {
                _ = try JSONDecoder().decode(IconSpec.self, from: data)
            }
        }
    }

    // MARK: - Tint exhaustiveness

    @Test("All tint cases round-trip")
    func tintRoundTrip() throws {
        for tint in [IconSpec.Tint.accent, .blue, .purple, .pink, .red,
                     .orange, .yellow, .green, .teal, .mono] {
            let spec = IconSpec.glassFrame(symbol: "star.fill", tint: tint)
            let data = try JSONEncoder().encode(spec)
            let decoded = try JSONDecoder().decode(IconSpec.self, from: data)
            #expect(decoded == spec)
        }
    }

    // MARK: - Hashable stability

    @Test("Equal specs hash equal")
    func hashEquality() {
        let a = IconSpec.glassFrame(symbol: "bolt.fill", tint: .orange)
        let b = IconSpec.glassFrame(symbol: "bolt.fill", tint: .orange)
        var set = Set<IconSpec>()
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}

@Suite("VirtualMachineMetadata backward compatibility", .tags(.configuration))
struct VirtualMachineMetadataMigrationTests {

    @Test("Pre-iconSpec metadata still decodes with iconSpec = nil")
    func legacyMetadataDecodes() throws {
        // A metadata.json written before the iconSpec field existed.
        let legacy = """
        {
            "id": "\(UUID().uuidString)",
            "createdAt": \(Date().timeIntervalSinceReferenceDate),
            "setupCompleted": false,
            "isEphemeral": false
        }
        """
        let decoded = try JSONDecoder().decode(
            VirtualMachineMetadata.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.iconSpec == nil)
        #expect(decoded.setupCompleted == false)
    }

    @Test("Current metadata round-trips with iconSpec")
    func currentMetadataRoundTrip() throws {
        var metadata = VirtualMachineMetadata()
        metadata.iconSpec = .glassFrame(symbol: "cpu", tint: .teal)

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(VirtualMachineMetadata.self, from: data)

        #expect(decoded.iconSpec == metadata.iconSpec)
        #expect(decoded.id == metadata.id)
    }
}
