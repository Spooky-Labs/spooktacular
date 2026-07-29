import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

@Suite("VirtualMachineBundle overlay", .tags(.lifecycle))
struct VirtualMachineBundleOverlayTests {

    private static let size: UInt64 = 2 * 1024 * 1024 * 1024

    private struct Base {
        let image: URL
        let auxiliary: URL
        let hardwareModel: URL
        let layerUUID: UUID
    }

    @available(macOS 27, *)
    private func makeBase(in temp: TempDirectory) throws -> Base {
        let image = temp.file("base.asif")
        let layerUUID = try DiskStack.createBase(at: image, sizeInBytes: Self.size)
        let auxiliary = temp.file("auxiliary.bin")
        let hardwareModel = temp.file("hardware-model.bin")
        // Stand-ins: the overlay code copies these byte-for-byte and
        // never interprets them, so real Virtualization blobs would add
        // an installer dependency without adding coverage.
        try Data([0x01, 0x02]).write(to: auxiliary)
        try Data([0x03, 0x04]).write(to: hardwareModel)
        return Base(
            image: image,
            auxiliary: auxiliary,
            hardwareModel: hardwareModel,
            layerUUID: layerUUID
        )
    }

    @available(macOS 27, *)
    private func makeBundle(
        in temp: TempDirectory,
        base: Base,
        displayName: String,
        publications: [PortPublication] = []
    ) throws -> VirtualMachineBundle {
        try VirtualMachineBundle.createOverlayBacked(
            at: temp.file("\(UUID().uuidString).vm"),
            spec: VirtualMachineSpecification(diskSizeInBytes: Self.size, guestOS: .macOS),
            displayName: displayName,
            base: BaseImageReference(buildVersion: "27A5301a", layerUUID: base.layerUUID),
            baseImageURL: base.image,
            baseAuxiliaryURL: base.auxiliary,
            baseHardwareModelURL: base.hardwareModel,
            network: GuestNetworkAllocation(
                subnetAddress: "192.168.99.0",
                subnetMask: "255.255.255.0",
                guestAddress: "192.168.99.3"
            ),
            publications: publications
        )
    }

    @available(macOS 27, *)
    @Test("overlay-backed create produces an overlay instead of a standalone disk")
    func createsOverlayNotDiskImage() throws {
        let temp = TempDirectory()
        let base = try makeBase(in: temp)
        let bundle = try makeBundle(in: temp, base: base, displayName: "overlay-vm")

        #expect(bundle.hasOverlay)
        #expect(FileManager.default.fileExists(atPath: bundle.overlayURL.path))
        let diskImage = bundle.url.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
        #expect(!FileManager.default.fileExists(atPath: diskImage.path))
    }

    @available(macOS 27, *)
    @Test("auxiliary storage and hardware model are cloned from the base")
    func clonesPlatformFiles() throws {
        let temp = TempDirectory()
        let base = try makeBase(in: temp)
        let bundle = try makeBundle(in: temp, base: base, displayName: "clone-vm")

        let auxiliary = bundle.url.appendingPathComponent(VirtualMachineBundle.auxiliaryStorageFileName)
        let model = bundle.url.appendingPathComponent(VirtualMachineBundle.hardwareModelFileName)
        #expect(try Data(contentsOf: auxiliary) == Data([0x01, 0x02]))
        // The hardware model must match the one the aux file was made
        // with, so it is copied from the same base rather than derived.
        #expect(try Data(contentsOf: model) == Data([0x03, 0x04]))
    }

    @available(macOS 27, *)
    @Test("each VM gets its own machine identifier")
    func mintsUniqueIdentifier() throws {
        let temp = TempDirectory()
        let base = try makeBase(in: temp)
        let first = try makeBundle(in: temp, base: base, displayName: "vm-one")
        let second = try makeBundle(in: temp, base: base, displayName: "vm-two")

        let firstID = try Data(
            contentsOf: first.url.appendingPathComponent(VirtualMachineBundle.machineIdentifierFileName)
        )
        let secondID = try Data(
            contentsOf: second.url.appendingPathComponent(VirtualMachineBundle.machineIdentifierFileName)
        )
        #expect(firstID != secondID, "two VMs must never share a machine identifier")
    }

    @available(macOS 27, *)
    @Test("provenance, network and publications are recorded in metadata")
    func recordsProvenance() throws {
        let temp = TempDirectory()
        let base = try makeBase(in: temp)
        let bundle = try makeBundle(
            in: temp,
            base: base,
            displayName: "meta-vm",
            publications: [PortPublication(hostPort: 18789, guestPort: 18789)]
        )

        #expect(bundle.metadata.baseImage?.layerUUID == base.layerUUID)
        #expect(bundle.metadata.baseImage?.buildVersion == "27A5301a")
        #expect(bundle.metadata.networkAllocation?.guestAddress == "192.168.99.3")
        #expect(bundle.metadata.portPublications == [PortPublication(hostPort: 18789, guestPort: 18789)])
    }

    @available(macOS 27, *)
    @Test("resetOverlay discards guest state and leaves the base untouched")
    func resetsOverlay() throws {
        let temp = TempDirectory()
        let base = try makeBase(in: temp)
        let bundle = try makeBundle(in: temp, base: base, displayName: "reset-vm")
        let identifierURL = bundle.url
            .appendingPathComponent(VirtualMachineBundle.machineIdentifierFileName)
        let before = try Data(contentsOf: identifierURL)

        try bundle.resetOverlay(baseImageURL: base.image, baseAuxiliaryURL: base.auxiliary)

        #expect(FileManager.default.fileExists(atPath: bundle.overlayURL.path))
        let after = try Data(contentsOf: identifierURL)
        #expect(before != after, "reset must mint a fresh machine identifier")
        #expect(
            try DiskStack.baseLayerUUID(at: base.image) == base.layerUUID,
            "the shared base must be provably unchanged by a reset"
        )
    }
}
