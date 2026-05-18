import Foundation
import Testing
@testable import SpooktacularCore

/// Track-K coverage: `NBDBackedDisk` + `DiskSyncMode` Codable
/// round-trip, backward-compat decode (pre-Track-K bundles
/// have no `networkBlockDevices` key), and default values.
@Suite("NBD storage spec (Track K)", .tags(.lifecycle))
struct NBDStorageSpecTests {

    @Test("Default disk values match the API contract")
    func defaults() {
        let url = URL(string: "nbd://localhost:10809/example")!
        let disk = NBDBackedDisk(url: url)
        #expect(disk.url == url)
        #expect(disk.timeoutSeconds == 0)       // 0 = framework default
        #expect(disk.forcedReadOnly == false)
        #expect(disk.syncMode == .full)
        #expect(disk.bus == .virtio)
    }

    @Test("NBDBackedDisk round-trips through JSON")
    func roundTrip() throws {
        let disk = NBDBackedDisk(
            url: URL(string: "nbd+unix:///data?socket=/tmp/nbd.sock")!,
            timeoutSeconds: 10,
            forcedReadOnly: true,
            syncMode: .none,
            bus: .virtio
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(disk)
        let decoded = try JSONDecoder().decode(NBDBackedDisk.self, from: data)
        #expect(decoded == disk)
    }

    @Test("DiskSyncMode has exactly the two cases Apple defines")
    func syncModeCases() {
        #expect(DiskSyncMode.allCases == [.full, .none])
    }

    @Test("DiskSyncMode round-trips with stable rawValues")
    func syncModeRoundTrip() throws {
        for mode in DiskSyncMode.allCases {
            let data = try JSONEncoder().encode(mode)
            let decoded = try JSONDecoder().decode(DiskSyncMode.self, from: data)
            #expect(decoded == mode)
        }
    }

    @Test("Spec default has no networkBlockDevices")
    func specDefault() {
        let spec = VirtualMachineSpecification()
        #expect(spec.networkBlockDevices.isEmpty)
    }

    @Test("Pre-Track-K JSON (no networkBlockDevices key) still decodes with empty default")
    func preTrackKBackwardCompat() throws {
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
          "clipboardSharingEnabled": true,
          "storageController": "virtio",
          "additionalDisks": []
        }
        """
        let decoded = try JSONDecoder().decode(
            VirtualMachineSpecification.self,
            from: Data(legacyJSON.utf8)
        )
        #expect(decoded.networkBlockDevices.isEmpty)
    }

    @Test("with(networkBlockDevices:) overrides only the NBD list")
    func withNetworkBlockDevices() {
        let disk = NBDBackedDisk(
            url: URL(string: "nbd://10.0.0.5:10809/vol")!
        )
        let original = VirtualMachineSpecification(cpuCount: 8)
        let updated = original.with(networkBlockDevices: [disk])
        #expect(updated.networkBlockDevices == [disk])
        #expect(updated.cpuCount == 8)
        #expect(updated.additionalDisks == original.additionalDisks)
    }
}
