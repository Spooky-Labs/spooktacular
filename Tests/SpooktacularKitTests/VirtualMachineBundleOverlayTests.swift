import Testing
import Foundation
import Virtualization
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

@Suite("VirtualMachineBundle overlay", .tags(.lifecycle))
struct VirtualMachineBundleOverlayTests {

    private static let size: UInt64 = 2 * 1024 * 1024 * 1024

    private struct Base {
        let image: URL
        let auxiliary: URL
        let hardwareModel: URL
        let machineIdentifier: URL
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
        let machineIdentifier = temp.file("machine-identifier.bin")
        try Data([0x01, 0x02]).write(to: auxiliary)
        try Data([0x03, 0x04]).write(to: hardwareModel)
        try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifier)
        return Base(
            image: image,
            auxiliary: auxiliary,
            hardwareModel: hardwareModel,
            machineIdentifier: machineIdentifier,
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
            baseMachineIdentifierURL: base.machineIdentifier,
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
    @Test("every VM inherits the identifier its base was installed with")
    func inheritsBaseIdentifier() throws {
        // Apple: a VM loaded from disk "must restore the hardwareModel,
        // machineIdentifier and auxiliaryStorage properties to their
        // original values". An overlay VM is the base's installed disk
        // loaded again, and the installer personalized the auxiliary
        // storage against the base's identifier — so regenerating one
        // per VM would pair personalized boot state with an identity it
        // was never signed for, and the guest would refuse to boot.
        let temp = TempDirectory()
        let base = try makeBase(in: temp)
        let expected = try Data(contentsOf: base.machineIdentifier)

        let first = try makeBundle(in: temp, base: base, displayName: "vm-one")
        let second = try makeBundle(in: temp, base: base, displayName: "vm-two")

        for bundle in [first, second] {
            let identifier = try Data(
                contentsOf: bundle.url.appendingPathComponent(
                    VirtualMachineBundle.machineIdentifierFileName
                )
            )
            #expect(identifier == expected, "VM must reuse the base's machine identifier")
        }
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
        let expected = try Data(contentsOf: base.machineIdentifier)

        try bundle.resetOverlay(
            baseImageURL: base.image,
            baseAuxiliaryURL: base.auxiliary,
            baseMachineIdentifierURL: base.machineIdentifier
        )

        #expect(FileManager.default.fileExists(atPath: bundle.overlayURL.path))
        let after = try Data(contentsOf: identifierURL)
        #expect(after == expected, "reset restores the base identity, paired with the restored aux")
        #expect(
            try DiskStack.baseLayerUUID(at: base.image) == base.layerUUID,
            "the shared base must be provably unchanged by a reset"
        )
    }

    @Test("an overlay-backed bundle reports the overlay as its writable disk")
    func writableDiskFollowsTheOverlay() throws {
        // Guest-tools injection resolved `disk.img` unconditionally, so every
        // overlay-backed macOS VM failed with "disk image not found" — naming
        // a file that is never created for these bundles.
        let temp = TempDirectory()
        let bundleURL = temp.file("\(UUID().uuidString).vm")
        let bundle = try VirtualMachineBundle.create(
            at: bundleURL,
            spec: VirtualMachineSpecification(),
            displayName: "overlay-vm"
        )

        #expect(
            bundle.writableDiskURL.lastPathComponent == VirtualMachineBundle.diskImageFileName,
            "without an overlay the writable disk is disk.img"
        )

        FileManager.default.createFile(atPath: bundle.overlayURL.path, contents: Data())

        #expect(bundle.hasOverlay)
        #expect(
            bundle.writableDiskURL.lastPathComponent == VirtualMachineBundle.overlayFileName,
            "with an overlay present the writable disk is the overlay"
        )
    }
}
