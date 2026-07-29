import Testing
import Foundation
@testable import SpooktacularCore

@Suite("VirtualMachineMetadata base/network fields", .tags(.lifecycle))
struct VirtualMachineMetadataBaseFieldsTests {

    @Test("new metadata defaults to no base, no network, no publications")
    func defaults() {
        let metadata = VirtualMachineMetadata(displayName: "test")
        #expect(metadata.baseImage == nil)
        #expect(metadata.networkAllocation == nil)
        #expect(metadata.portPublications.isEmpty)
    }

    @Test("the new fields survive a JSON round trip")
    func roundTrip() throws {
        var metadata = VirtualMachineMetadata(displayName: "test")
        let layerUUID = UUID()
        metadata.baseImage = BaseImageReference(buildVersion: "27A5301a", layerUUID: layerUUID)
        metadata.networkAllocation = GuestNetworkAllocation(
            subnetAddress: "192.168.90.0",
            subnetMask: "255.255.255.0",
            guestAddress: "192.168.90.3"
        )
        metadata.portPublications = [PortPublication(hostPort: 8080, guestPort: 18789)]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(VirtualMachineMetadata.self, from: data)

        #expect(decoded.baseImage == BaseImageReference(buildVersion: "27A5301a", layerUUID: layerUUID))
        #expect(decoded.networkAllocation?.guestAddress == "192.168.90.3")
        #expect(decoded.portPublications == [PortPublication(hostPort: 8080, guestPort: 18789)])
    }

    @Test("metadata written before these fields existed still decodes")
    func forwardCompatibleDecode() throws {
        let legacy = """
        {
          "id": "5C4F7C0E-6E2C-4E0E-9B7A-4C2E1B9A1234",
          "displayName": "legacy",
          "createdAt": "2026-01-01T00:00:00Z",
          "setupCompleted": true,
          "isEphemeral": false
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try #require(legacy.data(using: .utf8))
        let decoded = try decoder.decode(VirtualMachineMetadata.self, from: data)
        #expect(decoded.baseImage == nil)
        #expect(decoded.networkAllocation == nil)
        #expect(decoded.portPublications.isEmpty)
    }
}
