import Testing
import Foundation
@testable import SpooktacularKit

/// Tests for shared folder persistence in VM bundles.
///
/// Validates that adding and removing shared folders correctly
/// updates the `config.json` inside a VM bundle, and that the
/// changes survive a reload from disk.
@Suite("Share persistence")
struct SharePersistenceTests {

    // MARK: - Helpers

    /// Creates a temporary VM bundle for testing.
    /// The caller is responsible for cleanup via the returned
    /// parent directory URL.
    private func makeTempBundle(
        spec: VirtualMachineSpecification = VirtualMachineSpecification()
    ) throws -> (bundle: VirtualMachineBundle, parentDir: URL) {
        let parentDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundleURL = parentDir.appendingPathComponent("test.vm")
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)
        return (bundle, parentDir)
    }

    /// Writes an updated spec to the bundle's config.json, mirroring
    /// the logic used by the share commands.
    private func writeSpec(_ spec: VirtualMachineSpecification, to bundleURL: URL) throws {
        let data = try VirtualMachineBundle.encoder.encode(spec)
        try data.write(
            to: bundleURL.appendingPathComponent(VirtualMachineBundle.configFileName)
        )
    }

    // MARK: - Add Tests

    @Test("Adding a shared folder persists to config.json")
    func addPersists() throws {
        let (bundle, parentDir) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        #expect(bundle.spec.sharedFolders.isEmpty)

        let newFolder = SharedFolder(
            hostPath: "/tmp/shared",
            tag: "myshare",
            readOnly: false
        )
        let updatedSpec = VirtualMachineSpecification(
            cpuCount: bundle.spec.cpuCount,
            memorySizeInBytes: bundle.spec.memorySizeInBytes,
            diskSizeInBytes: bundle.spec.diskSizeInBytes,
            displayCount: bundle.spec.displayCount,
            networkMode: bundle.spec.networkMode,
            audioEnabled: bundle.spec.audioEnabled,
            microphoneEnabled: bundle.spec.microphoneEnabled,
            sharedFolders: bundle.spec.sharedFolders + [newFolder],
            macAddress: bundle.spec.macAddress,
            autoResizeDisplay: bundle.spec.autoResizeDisplay,
            clipboardSharingEnabled: bundle.spec.clipboardSharingEnabled
        )
        try writeSpec(updatedSpec, to: bundle.url)

        // Reload from disk and verify.
        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.sharedFolders.count == 1)
        #expect(reloaded.spec.sharedFolders[0].hostPath == "/tmp/shared")
        #expect(reloaded.spec.sharedFolders[0].tag == "myshare")
        #expect(reloaded.spec.sharedFolders[0].readOnly == false)
    }

    @Test("Adding a read-only shared folder persists correctly")
    func addReadOnlyPersists() throws {
        let (bundle, parentDir) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let newFolder = SharedFolder(
            hostPath: "/data",
            tag: "data",
            readOnly: true
        )
        let updatedSpec = VirtualMachineSpecification(
            cpuCount: bundle.spec.cpuCount,
            memorySizeInBytes: bundle.spec.memorySizeInBytes,
            diskSizeInBytes: bundle.spec.diskSizeInBytes,
            displayCount: bundle.spec.displayCount,
            networkMode: bundle.spec.networkMode,
            audioEnabled: bundle.spec.audioEnabled,
            microphoneEnabled: bundle.spec.microphoneEnabled,
            sharedFolders: [newFolder],
            macAddress: bundle.spec.macAddress,
            autoResizeDisplay: bundle.spec.autoResizeDisplay,
            clipboardSharingEnabled: bundle.spec.clipboardSharingEnabled
        )
        try writeSpec(updatedSpec, to: bundle.url)

        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.sharedFolders.count == 1)
        #expect(reloaded.spec.sharedFolders[0].readOnly == true)
    }

    @Test("Adding multiple shared folders preserves order")
    func addMultiple() throws {
        let (bundle, parentDir) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let folders = [
            SharedFolder(hostPath: "/tmp/a", tag: "alpha"),
            SharedFolder(hostPath: "/tmp/b", tag: "beta"),
            SharedFolder(hostPath: "/tmp/c", tag: "gamma", readOnly: true),
        ]
        let updatedSpec = VirtualMachineSpecification(
            cpuCount: bundle.spec.cpuCount,
            memorySizeInBytes: bundle.spec.memorySizeInBytes,
            diskSizeInBytes: bundle.spec.diskSizeInBytes,
            displayCount: bundle.spec.displayCount,
            networkMode: bundle.spec.networkMode,
            audioEnabled: bundle.spec.audioEnabled,
            microphoneEnabled: bundle.spec.microphoneEnabled,
            sharedFolders: folders,
            macAddress: bundle.spec.macAddress,
            autoResizeDisplay: bundle.spec.autoResizeDisplay,
            clipboardSharingEnabled: bundle.spec.clipboardSharingEnabled
        )
        try writeSpec(updatedSpec, to: bundle.url)

        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.sharedFolders.count == 3)
        #expect(reloaded.spec.sharedFolders[0].tag == "alpha")
        #expect(reloaded.spec.sharedFolders[1].tag == "beta")
        #expect(reloaded.spec.sharedFolders[2].tag == "gamma")
    }

    // MARK: - Remove Tests

    @Test("Removing a shared folder persists to config.json")
    func removePersists() throws {
        let folder = SharedFolder(hostPath: "/tmp/shared", tag: "myshare")
        let initialSpec = VirtualMachineSpecification(sharedFolders: [folder])

        let (bundle, parentDir) = try makeTempBundle(spec: initialSpec)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        #expect(bundle.spec.sharedFolders.count == 1)

        // Remove the folder by filtering out its tag.
        let filtered = bundle.spec.sharedFolders.filter { $0.tag != "myshare" }
        let updatedSpec = VirtualMachineSpecification(
            cpuCount: bundle.spec.cpuCount,
            memorySizeInBytes: bundle.spec.memorySizeInBytes,
            diskSizeInBytes: bundle.spec.diskSizeInBytes,
            displayCount: bundle.spec.displayCount,
            networkMode: bundle.spec.networkMode,
            audioEnabled: bundle.spec.audioEnabled,
            microphoneEnabled: bundle.spec.microphoneEnabled,
            sharedFolders: filtered,
            macAddress: bundle.spec.macAddress,
            autoResizeDisplay: bundle.spec.autoResizeDisplay,
            clipboardSharingEnabled: bundle.spec.clipboardSharingEnabled
        )
        try writeSpec(updatedSpec, to: bundle.url)

        // Reload from disk and verify empty.
        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.sharedFolders.isEmpty)
    }

    @Test("Removing one folder leaves others intact")
    func removeSelectivelyPreservesOthers() throws {
        let folders = [
            SharedFolder(hostPath: "/tmp/a", tag: "alpha"),
            SharedFolder(hostPath: "/tmp/b", tag: "beta"),
            SharedFolder(hostPath: "/tmp/c", tag: "gamma"),
        ]
        let initialSpec = VirtualMachineSpecification(sharedFolders: folders)

        let (bundle, parentDir) = try makeTempBundle(spec: initialSpec)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let filtered = bundle.spec.sharedFolders.filter { $0.tag != "beta" }
        let updatedSpec = VirtualMachineSpecification(
            cpuCount: bundle.spec.cpuCount,
            memorySizeInBytes: bundle.spec.memorySizeInBytes,
            diskSizeInBytes: bundle.spec.diskSizeInBytes,
            displayCount: bundle.spec.displayCount,
            networkMode: bundle.spec.networkMode,
            audioEnabled: bundle.spec.audioEnabled,
            microphoneEnabled: bundle.spec.microphoneEnabled,
            sharedFolders: filtered,
            macAddress: bundle.spec.macAddress,
            autoResizeDisplay: bundle.spec.autoResizeDisplay,
            clipboardSharingEnabled: bundle.spec.clipboardSharingEnabled
        )
        try writeSpec(updatedSpec, to: bundle.url)

        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.sharedFolders.count == 2)
        #expect(reloaded.spec.sharedFolders.map(\.tag) == ["alpha", "gamma"])
    }

    // MARK: - List Tests

    @Test("Empty bundle reports no shared folders")
    func listEmpty() throws {
        let (bundle, parentDir) = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let loaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(loaded.spec.sharedFolders.isEmpty)
    }

    @Test("Bundle with shares reports correct folder details")
    func listWithShares() throws {
        let folders = [
            SharedFolder(hostPath: "/Users/test/code", tag: "code", readOnly: false),
            SharedFolder(hostPath: "/Users/test/data", tag: "data", readOnly: true),
        ]
        let initialSpec = VirtualMachineSpecification(sharedFolders: folders)

        let (_, parentDir) = try makeTempBundle(spec: initialSpec)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let bundleURL = parentDir.appendingPathComponent("test.vm")
        let loaded = try VirtualMachineBundle.load(from: bundleURL)

        #expect(loaded.spec.sharedFolders.count == 2)
        #expect(loaded.spec.sharedFolders[0].hostPath == "/Users/test/code")
        #expect(loaded.spec.sharedFolders[0].tag == "code")
        #expect(loaded.spec.sharedFolders[0].readOnly == false)
        #expect(loaded.spec.sharedFolders[1].hostPath == "/Users/test/data")
        #expect(loaded.spec.sharedFolders[1].tag == "data")
        #expect(loaded.spec.sharedFolders[1].readOnly == true)
    }

    // MARK: - Spec Preservation Tests

    @Test("Adding a share preserves other spec fields")
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
            macAddress: "AA:BB:CC:DD:EE:FF",
            autoResizeDisplay: false,
            clipboardSharingEnabled: false
        )

        let (bundle, parentDir) = try makeTempBundle(spec: initialSpec)
        defer { try? FileManager.default.removeItem(at: parentDir) }

        let newFolder = SharedFolder(hostPath: "/tmp/test", tag: "test")
        let updatedSpec = VirtualMachineSpecification(
            cpuCount: bundle.spec.cpuCount,
            memorySizeInBytes: bundle.spec.memorySizeInBytes,
            diskSizeInBytes: bundle.spec.diskSizeInBytes,
            displayCount: bundle.spec.displayCount,
            networkMode: bundle.spec.networkMode,
            audioEnabled: bundle.spec.audioEnabled,
            microphoneEnabled: bundle.spec.microphoneEnabled,
            sharedFolders: bundle.spec.sharedFolders + [newFolder],
            macAddress: bundle.spec.macAddress,
            autoResizeDisplay: bundle.spec.autoResizeDisplay,
            clipboardSharingEnabled: bundle.spec.clipboardSharingEnabled
        )
        try writeSpec(updatedSpec, to: bundle.url)

        let reloaded = try VirtualMachineBundle.load(from: bundle.url)
        #expect(reloaded.spec.cpuCount == 8)
        #expect(reloaded.spec.memorySizeInBytes == 16 * 1024 * 1024 * 1024)
        #expect(reloaded.spec.diskSizeInBytes == 100 * 1024 * 1024 * 1024)
        #expect(reloaded.spec.displayCount == 2)
        #expect(reloaded.spec.audioEnabled == false)
        #expect(reloaded.spec.microphoneEnabled == true)
        #expect(reloaded.spec.macAddress == "AA:BB:CC:DD:EE:FF")
        #expect(reloaded.spec.autoResizeDisplay == false)
        #expect(reloaded.spec.clipboardSharingEnabled == false)
        #expect(reloaded.spec.sharedFolders.count == 1)
        #expect(reloaded.spec.sharedFolders[0].tag == "test")
    }
}
