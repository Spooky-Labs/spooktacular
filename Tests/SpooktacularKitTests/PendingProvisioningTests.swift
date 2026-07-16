import Testing
import Foundation
@testable import SpooktacularCore

@Suite("Pending provisioning persistence")
struct PendingProvisioningTests {

    private let enc = JSONEncoder()
    private let dec = JSONDecoder()

    /// A password only ever used to prove it does NOT leak into any
    /// persisted metadata artifact.
    private let samplePassword = "hunter2hunter2-secret"

    @Test("PendingProvisioning marker survives a Codable round-trip")
    func markerRoundTrip() throws {
        let marker = PendingProvisioning(
            fullName: "Desktop User",
            username: "admin",
            logsInAutomatically: true,
            enablesRemoteLogin: true
        )
        let back = try dec.decode(PendingProvisioning.self, from: try enc.encode(marker))
        #expect(back == marker)
    }

    @Test("marker <-> spec conversion is lossless on the non-secret fields")
    func markerSpecConversion() throws {
        let spec = GuestProvisioningSpec(
            fullName: "Desktop User",
            username: "admin",
            password: samplePassword,
            logsInAutomatically: true,
            enablesRemoteLogin: true
        )
        // Dropping to a marker keeps every non-secret field.
        let marker = spec.pendingMarker
        #expect(marker.fullName == spec.fullName)
        #expect(marker.username == spec.username)
        #expect(marker.logsInAutomatically == spec.logsInAutomatically)
        #expect(marker.enablesRemoteLogin == spec.enablesRemoteLogin)

        // Re-pairing with the Keychain-held password reconstitutes the
        // original spec exactly.
        #expect(marker.spec(password: samplePassword) == spec)
    }

    @Test("metadata carries a pending marker through encode/decode")
    func metadataCarriesMarker() throws {
        var meta = VirtualMachineMetadata(displayName: "desktop-vm")
        meta.pendingProvisioning = PendingProvisioning(
            fullName: "Desktop User",
            username: "admin",
            logsInAutomatically: true,
            enablesRemoteLogin: true
        )
        let back = try dec.decode(VirtualMachineMetadata.self, from: try enc.encode(meta))
        #expect(back.pendingProvisioning?.username == "admin")
        #expect(back.pendingProvisioning?.enablesRemoteLogin == true)
    }

    @Test("nil pending marker means already-provisioned / never-needed")
    func metadataNilMarker() throws {
        let meta = VirtualMachineMetadata(displayName: "runner-vm")
        #expect(meta.pendingProvisioning == nil)
        let back = try dec.decode(VirtualMachineMetadata.self, from: try enc.encode(meta))
        #expect(back.pendingProvisioning == nil)
    }

    @Test("old metadata.json without the field decodes with nil (backward compatible)")
    func backwardCompatible() throws {
        // A metadata.json written before pendingProvisioning existed.
        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "displayName": "legacy-vm",
          "createdAt": 700000000,
          "setupCompleted": true
        }
        """
        let meta = try dec.decode(VirtualMachineMetadata.self, from: Data(legacy.utf8))
        #expect(meta.pendingProvisioning == nil)
        #expect(meta.displayName == "legacy-vm")
    }

    /// The core security invariant: the account password must NEVER be
    /// written to `metadata.json`. Building the marker from a full spec
    /// (as `spook create` does) and encoding the metadata must produce
    /// JSON that contains neither the password nor any `password` key.
    @Test("encoded metadata JSON never contains the account password")
    func noPasswordInEncodedMetadata() throws {
        let spec = GuestProvisioningSpec(
            fullName: "Desktop User",
            username: "admin",
            password: samplePassword,
            logsInAutomatically: true,
            enablesRemoteLogin: true
        )
        var meta = VirtualMachineMetadata(displayName: "desktop-vm")
        meta.pendingProvisioning = spec.pendingMarker

        let data = try enc.encode(meta)
        let jsonString = try #require(String(data: data, encoding: .utf8))

        #expect(!jsonString.contains(samplePassword))
        // Belt-and-suspenders: no `password` field of any kind survives.
        #expect(!jsonString.lowercased().contains("password"))
    }
}
