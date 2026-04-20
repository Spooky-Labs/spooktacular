import Foundation
import Testing
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

/// Track-G coverage: `StorageController` + `AdditionalDisk`
/// fields on `VirtualMachineSpecification`, plus the
/// backward-compatible decode path that lets a pre-Track-G
/// bundle load without its JSON carrying the new keys.
@Suite("Storage spec (Track G)", .tags(.lifecycle))
struct StorageSpecTests {

    @Test("Default storage controller is virtio")
    func defaultController() {
        let spec = VirtualMachineSpecification()
        #expect(spec.storageController == .virtio)
    }

    @Test("Default additionalDisks is empty")
    func defaultAdditionalDisks() {
        let spec = VirtualMachineSpecification()
        #expect(spec.additionalDisks.isEmpty)
    }

    @Test("Explicit .nvme controller round-trips through JSON")
    func nvmeRoundTrip() throws {
        let spec = VirtualMachineSpecification(storageController: .nvme)
        let data = try VirtualMachineBundle.encoder.encode(spec)
        let decoded = try VirtualMachineBundle.decoder.decode(
            VirtualMachineSpecification.self,
            from: data
        )
        #expect(decoded.storageController == .nvme)
    }

    @Test("AdditionalDisk round-trips through JSON")
    func additionalDiskRoundTrip() throws {
        let disk = AdditionalDisk(hostPath: "/tmp/scratch.img", readOnly: true)
        let spec = VirtualMachineSpecification(additionalDisks: [disk])
        let data = try VirtualMachineBundle.encoder.encode(spec)
        let decoded = try VirtualMachineBundle.decoder.decode(
            VirtualMachineSpecification.self,
            from: data
        )
        #expect(decoded.additionalDisks == [disk])
        #expect(decoded.additionalDisks.first?.readOnly == true)
    }

    @Test("readOnly defaults to false on AdditionalDisk")
    func additionalDiskReadOnlyDefault() {
        let disk = AdditionalDisk(hostPath: "/tmp/x.img")
        #expect(disk.readOnly == false)
    }

    @Test("Decoding a pre-Track-G JSON (no storage keys) still succeeds, with defaults")
    func backwardCompatDecode() throws {
        // Emulates what `config.json` looked like before
        // Track G added `storageController` and
        // `additionalDisks`. The custom `init(from:)` uses
        // `decodeIfPresent` with defaults — that invariant
        // is the point of this test.
        let legacyJSON = """
        {
          "cpuCount": 4,
          "memorySizeInBytes": 8589934592,
          "diskSizeInBytes": 68719476736,
          "displayCount": 1,
          "networkMode": { "nat": {} },
          "audioEnabled": true,
          "microphoneEnabled": false,
          "sharedFolders": [],
          "autoResizeDisplay": true,
          "clipboardSharingEnabled": true
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoded = try VirtualMachineBundle.decoder.decode(
            VirtualMachineSpecification.self,
            from: data
        )
        #expect(decoded.storageController == .virtio)
        #expect(decoded.additionalDisks.isEmpty)
        #expect(decoded.cpuCount == 4)
    }

    @Test("with(storageController:) overrides only that field")
    func withStorageController() {
        let original = VirtualMachineSpecification(cpuCount: 8)
        let updated = original.with(storageController: .nvme)
        #expect(updated.storageController == .nvme)
        #expect(updated.cpuCount == 8)
        #expect(updated.additionalDisks == original.additionalDisks)
    }

    @Test("with(additionalDisks:) overrides only that field")
    func withAdditionalDisks() {
        let disk = AdditionalDisk(hostPath: "/tmp/a.img")
        let original = VirtualMachineSpecification()
        let updated = original.with(additionalDisks: [disk])
        #expect(updated.additionalDisks == [disk])
        #expect(updated.storageController == original.storageController)
    }

    @Test("StorageController displayName is stable for GUI picker")
    func displayNames() {
        #expect(StorageController.virtio.displayName == "Virtio Block")
        #expect(StorageController.nvme.displayName == "NVMe")
    }

    @Test("StorageController.allCases enumerates both options")
    func allCases() {
        #expect(StorageController.allCases == [.virtio, .nvme])
    }
}
