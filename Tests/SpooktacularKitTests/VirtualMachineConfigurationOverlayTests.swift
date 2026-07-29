import Testing
import Foundation
import Virtualization
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

@Suite("VirtualMachineConfiguration overlay storage", .tags(.configuration))
struct VirtualMachineConfigurationOverlayTests {

    private static let size: UInt64 = 2 * 1024 * 1024 * 1024

    @available(macOS 27, *)
    private func makeOverlayBundle(
        in temp: TempDirectory,
        recordedBaseUUID: UUID? = nil
    ) throws -> (bundle: VirtualMachineBundle, baseImage: URL, baseUUID: UUID) {
        let baseImage = temp.file("base.asif")
        let baseUUID = try DiskStack.createBase(at: baseImage, sizeInBytes: Self.size)
        let auxiliary = temp.file("auxiliary.bin")
        let model = temp.file("hardware-model.bin")
        try Data([0x01]).write(to: auxiliary)
        try Data([0x02]).write(to: model)

        let bundle = try VirtualMachineBundle.createOverlayBacked(
            at: temp.file("\(UUID().uuidString).vm"),
            spec: VirtualMachineSpecification(diskSizeInBytes: Self.size, guestOS: .macOS),
            displayName: "cfg-vm",
            base: BaseImageReference(
                buildVersion: "27A5301a",
                layerUUID: recordedBaseUUID ?? baseUUID
            ),
            baseImageURL: baseImage,
            baseAuxiliaryURL: auxiliary,
            baseHardwareModelURL: model,
            network: GuestNetworkAllocation(
                subnetAddress: "192.168.98.0",
                subnetMask: "255.255.255.0",
                guestAddress: "192.168.98.3"
            ),
            publications: []
        )
        return (bundle, baseImage, baseUUID)
    }

    @available(macOS 27, *)
    @Test("an overlay-backed macOS bundle attaches its stack as the primary disk")
    func attachesStack() throws {
        let temp = TempDirectory()
        let made = try makeOverlayBundle(in: temp)

        let attachment = try VirtualMachineConfiguration.primaryDiskAttachment(
            for: made.bundle,
            baseImageURL: made.baseImage
        )

        let imageAttachment = try #require(attachment as? VZDiskImageStorageDeviceAttachment)
        // The stack's URL is its topmost layer — this VM's overlay.
        #expect(imageAttachment.url.lastPathComponent == VirtualMachineBundle.overlayFileName)
    }

    @available(macOS 27, *)
    @Test("a drifted base is rejected with a typed error")
    func rejectsDrift() throws {
        let temp = TempDirectory()
        let recorded = UUID()
        let made = try makeOverlayBundle(in: temp, recordedBaseUUID: recorded)

        #expect(throws: DiskStackError.baseDrift(expected: recorded, found: made.baseUUID)) {
            try VirtualMachineConfiguration.primaryDiskAttachment(
                for: made.bundle,
                baseImageURL: made.baseImage
            )
        }
    }

    @available(macOS 27, *)
    @Test("an overlay bundle without a base image path is reported as incomplete")
    func requiresBaseImagePath() throws {
        let temp = TempDirectory()
        let made = try makeOverlayBundle(in: temp)

        #expect(throws: BaseImageStoreError.incomplete(build: "27A5301a")) {
            try VirtualMachineConfiguration.primaryDiskAttachment(
                for: made.bundle,
                baseImageURL: nil
            )
        }
    }

    @Test("a bundle with no base reference still uses its standalone disk image")
    func standaloneDiskUnchanged() throws {
        let temp = TempDirectory()
        let bundleURL = temp.file("\(UUID().uuidString).vm")
        let bundle = try VirtualMachineBundle.create(
            at: bundleURL,
            spec: VirtualMachineSpecification(diskSizeInBytes: Self.size, guestOS: .linux),
            displayName: "linux-vm"
        )
        // Linux bundles own a plain disk.img.
        let diskURL = bundleURL.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
        FileManager.default.createFile(atPath: diskURL.path, contents: Data(count: 1024))

        let attachment = try VirtualMachineConfiguration.primaryDiskAttachment(
            for: bundle,
            baseImageURL: nil
        )

        let imageAttachment = try #require(attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(imageAttachment.url.lastPathComponent == VirtualMachineBundle.diskImageFileName)
    }
}
