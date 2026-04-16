import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

/// Tests for shared folder persistence in VM bundles.
///
/// Validates that adding and removing shared folders correctly
/// updates the `config.json` inside a VM bundle, and that the
/// changes survive a reload from disk.
@Suite("Share persistence", .tags(.lifecycle))
struct SharePersistenceTests {

    // MARK: - Helpers

    private func makeTempBundle(
        spec: VirtualMachineSpecification = VirtualMachineSpecification()
    ) throws -> (bundle: VirtualMachineBundle, tmp: TempDirectory) {
        let tmp = TempDirectory()
        let bundleURL = tmp.file("test.vm")
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)
        return (bundle, tmp)
    }

    private func writeSpec(_ spec: VirtualMachineSpecification, to bundleURL: URL) throws {
        let data = try VirtualMachineBundle.encoder.encode(spec)
        try data.write(
            to: bundleURL.appendingPathComponent(VirtualMachineBundle.configFileName)
        )
    }

    // MARK: - Add Tests

    @Suite("Add shared folders", .tags(.lifecycle))
    struct AddTests {

        @Test("Adding a shared folder persists to config.json", .timeLimit(.minutes(1)))
        func addPersists() throws {
            let outer = SharePersistenceTests()
            let (bundle, _tmp) = try outer.makeTempBundle()
            try #require(bundle.spec.sharedFolders.isEmpty, "Must start with no shared folders")

            let newFolder = SharedFolder(hostPath: "/tmp/shared", tag: "myshare", readOnly: false)
            let updatedSpec = bundle.spec.with(
                sharedFolders: bundle.spec.sharedFolders + [newFolder]
            )
            try outer.writeSpec(updatedSpec, to: bundle.url)

            let reloaded = try VirtualMachineBundle.load(from: bundle.url)
            let folder = try #require(reloaded.spec.sharedFolders.first)
            #expect(folder.hostPath == "/tmp/shared")
            #expect(folder.tag == "myshare")
            #expect(folder.readOnly == false)
        }

        @Test("Adding a read-only shared folder persists correctly", .timeLimit(.minutes(1)))
        func addReadOnlyPersists() throws {
            let outer = SharePersistenceTests()
            let (bundle, _tmp) = try outer.makeTempBundle()

            let newFolder = SharedFolder(hostPath: "/data", tag: "data", readOnly: true)
            let updatedSpec = bundle.spec.with(sharedFolders: [newFolder])
            try outer.writeSpec(updatedSpec, to: bundle.url)

            let reloaded = try VirtualMachineBundle.load(from: bundle.url)
            let folder = try #require(reloaded.spec.sharedFolders.first)
            #expect(folder.readOnly == true)
        }

        @Test("Adding multiple shared folders preserves order", .timeLimit(.minutes(1)))
        func addMultiple() throws {
            let outer = SharePersistenceTests()
            let (bundle, _tmp) = try outer.makeTempBundle()

            let folders = [
                SharedFolder(hostPath: "/tmp/a", tag: "alpha"),
                SharedFolder(hostPath: "/tmp/b", tag: "beta"),
                SharedFolder(hostPath: "/tmp/c", tag: "gamma", readOnly: true),
            ]
            let updatedSpec = bundle.spec.with(sharedFolders: folders)
            try outer.writeSpec(updatedSpec, to: bundle.url)

            let reloaded = try VirtualMachineBundle.load(from: bundle.url)
            let tags = reloaded.spec.sharedFolders.map(\.tag)
            #expect(tags == ["alpha", "beta", "gamma"])
        }
    }

    // MARK: - Remove Tests

    @Suite("Remove shared folders", .tags(.lifecycle))
    struct RemoveTests {

        @Test("Removing a shared folder persists to config.json", .timeLimit(.minutes(1)))
        func removePersists() throws {
            let outer = SharePersistenceTests()
            let folder = SharedFolder(hostPath: "/tmp/shared", tag: "myshare")
            let (bundle, _tmp) = try outer.makeTempBundle(
                spec: VirtualMachineSpecification(sharedFolders: [folder])
            )
            try #require(bundle.spec.sharedFolders.count == 1, "Must start with one folder")

            let filtered = bundle.spec.sharedFolders.filter { $0.tag != "myshare" }
            let updatedSpec = bundle.spec.with(sharedFolders: filtered)
            try outer.writeSpec(updatedSpec, to: bundle.url)

            let reloaded = try VirtualMachineBundle.load(from: bundle.url)
            #expect(reloaded.spec.sharedFolders.isEmpty)
        }

        @Test("Removing one folder leaves others intact", .timeLimit(.minutes(1)))
        func removeSelectivelyPreservesOthers() throws {
            let outer = SharePersistenceTests()
            let folders = [
                SharedFolder(hostPath: "/tmp/a", tag: "alpha"),
                SharedFolder(hostPath: "/tmp/b", tag: "beta"),
                SharedFolder(hostPath: "/tmp/c", tag: "gamma"),
            ]
            let (bundle, _tmp) = try outer.makeTempBundle(
                spec: VirtualMachineSpecification(sharedFolders: folders)
            )

            let filtered = bundle.spec.sharedFolders.filter { $0.tag != "beta" }
            let updatedSpec = bundle.spec.with(sharedFolders: filtered)
            try outer.writeSpec(updatedSpec, to: bundle.url)

            let reloaded = try VirtualMachineBundle.load(from: bundle.url)
            #expect(reloaded.spec.sharedFolders.map(\.tag) == ["alpha", "gamma"])
        }
    }

    // MARK: - List Tests

    @Test("Empty bundle reports no shared folders", .timeLimit(.minutes(1)))
    func listEmpty() throws {
        let (bundle, _tmp) = try makeTempBundle()
        let loaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(loaded.spec.sharedFolders.isEmpty)
    }

    @Test("Bundle with shares reports correct folder details", .timeLimit(.minutes(1)))
    func listWithShares() throws {
        let folders = [
            SharedFolder(hostPath: "/Users/test/code", tag: "code", readOnly: false),
            SharedFolder(hostPath: "/Users/test/data", tag: "data", readOnly: true),
        ]
        let (bundle, _tmp) = try makeTempBundle(
            spec: VirtualMachineSpecification(sharedFolders: folders)
        )

        let loaded = try VirtualMachineBundle.load(from: bundle.url)
        let first = try #require(loaded.spec.sharedFolders.first)
        let second = try #require(loaded.spec.sharedFolders.last)

        #expect(first.hostPath == "/Users/test/code")
        #expect(first.tag == "code")
        #expect(first.readOnly == false)
        #expect(second.hostPath == "/Users/test/data")
        #expect(second.tag == "data")
        #expect(second.readOnly == true)
    }

    // MARK: - Spec Preservation

    @Test("Adding a share preserves other spec fields", .timeLimit(.minutes(1)))
    func addPreservesOtherFields() throws {
        let initialSpec = VirtualMachineSpecification(
            cpuCount: 8,
            memorySizeInBytes: 16 * 1024 * 1024 * 1024,
            diskSizeInBytes: 100 * 1024 * 1024 * 1024,
            displayCount: 2,
            networkMode: .nat,
            audioEnabled: false,
            microphoneEnabled: true,
            sharedFolders: [],
            macAddress: MACAddress("AA:BB:CC:DD:EE:FF")!,
            autoResizeDisplay: false,
            clipboardSharingEnabled: false
        )

        let (bundle, _tmp) = try makeTempBundle(spec: initialSpec)

        let newFolder = SharedFolder(hostPath: "/tmp/test", tag: "test")
        let updatedSpec = bundle.spec.with(
            sharedFolders: bundle.spec.sharedFolders + [newFolder]
        )
        try writeSpec(updatedSpec, to: bundle.url)

        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.cpuCount == 8)
        #expect(reloaded.spec.memorySizeInBytes == UInt64(16) * 1024 * 1024 * 1024)
        #expect(reloaded.spec.diskSizeInBytes == UInt64(100) * 1024 * 1024 * 1024)
        #expect(reloaded.spec.displayCount == 2)
        #expect(reloaded.spec.audioEnabled == false)
        #expect(reloaded.spec.microphoneEnabled == true)
        #expect(reloaded.spec.macAddress == MACAddress("aa:bb:cc:dd:ee:ff"))
        #expect(reloaded.spec.autoResizeDisplay == false)
        #expect(reloaded.spec.clipboardSharingEnabled == false)
        let folder = try #require(reloaded.spec.sharedFolders.first)
        #expect(folder.tag == "test")
    }
}
