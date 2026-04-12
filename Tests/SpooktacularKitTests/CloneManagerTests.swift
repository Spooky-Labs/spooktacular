import Testing
import Foundation
@testable import SpooktacularKit

@Suite("CloneManager")
struct CloneManagerTests {

    /// Creates a temporary bundle with a fake disk image for testing.
    private func makeTestBundle() throws -> (VirtualMachineBundle, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundleURL = tempDir.appendingPathComponent("source.vm")
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification(cpuCount: 6))

        // Write fake disk.img and platform artifacts
        let diskURL = bundleURL.appendingPathComponent("disk.img")
        try Data("fake-disk-content".utf8).write(to: diskURL)

        let auxURL = bundleURL.appendingPathComponent("auxiliary.bin")
        try Data("fake-aux-content".utf8).write(to: auxURL)

        let hwModelURL = bundleURL.appendingPathComponent("hardware-model.bin")
        try Data("fake-hardware-model".utf8).write(to: hwModelURL)

        let midURL = bundleURL.appendingPathComponent("machine-identifier.bin")
        try Data("original-machine-id".utf8).write(to: midURL)

        return (bundle, tempDir)
    }

    @Test("Creates a new bundle directory for the clone")
    func createsDirectory() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        let clone = try CloneManager.clone(source: source, to: destURL)

        #expect(FileManager.default.fileExists(atPath: destURL.path))
        #expect(clone.url == destURL)
    }

    @Test("Preserves the spec from the source bundle")
    func preservesSpec() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        let clone = try CloneManager.clone(source: source, to: destURL)

        #expect(clone.spec.cpuCount == source.spec.cpuCount)
        #expect(clone.spec.memorySizeInBytes == source.spec.memorySizeInBytes)
        #expect(clone.spec.networkMode == source.spec.networkMode)
    }

    @Test("Generates a new unique metadata ID for the clone")
    func newMetadataID() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        let clone = try CloneManager.clone(source: source, to: destURL)

        #expect(clone.metadata.id != source.metadata.id)
    }

    @Test("Inherits setupCompleted from the source")
    func inheritsSetupCompleted() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Simulate a source where setup is already done
        var updatedMetadata = source.metadata
        updatedMetadata.setupCompleted = true
        try VirtualMachineBundle.writeMetadata(updatedMetadata, to: source.url)

        let destURL = tempDir.appendingPathComponent("clone.vm")
        let clone = try CloneManager.clone(
            source: try VirtualMachineBundle.load(from: source.url),
            to: destURL
        )

        #expect(clone.metadata.setupCompleted == true)
    }

    @Test("Copies the disk image")
    func copiesDisk() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        _ = try CloneManager.clone(source: source, to: destURL)

        let cloneDisk = destURL.appendingPathComponent("disk.img")
        #expect(FileManager.default.fileExists(atPath: cloneDisk.path))

        let content = try String(data: Data(contentsOf: cloneDisk), encoding: .utf8)
        #expect(content == "fake-disk-content")
    }

    @Test("Copies auxiliary storage")
    func copiesAuxiliary() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        _ = try CloneManager.clone(source: source, to: destURL)

        let cloneAux = destURL.appendingPathComponent("auxiliary.bin")
        #expect(FileManager.default.fileExists(atPath: cloneAux.path))
    }

    @Test("Copies hardware model")
    func copiesHardwareModel() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        _ = try CloneManager.clone(source: source, to: destURL)

        let cloneHW = destURL.appendingPathComponent("hardware-model.bin")
        #expect(FileManager.default.fileExists(atPath: cloneHW.path))

        let content = try Data(contentsOf: cloneHW)
        let sourceContent = try Data(
            contentsOf: source.url.appendingPathComponent("hardware-model.bin")
        )
        #expect(content == sourceContent, "Hardware model must be identical to source")
    }

    @Test("Writes a NEW machine identifier (not copied from source)")
    func newMachineIdentifier() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        _ = try CloneManager.clone(source: source, to: destURL)

        let cloneMID = destURL.appendingPathComponent("machine-identifier.bin")
        #expect(FileManager.default.fileExists(atPath: cloneMID.path))

        let cloneData = try Data(contentsOf: cloneMID)
        let sourceData = try Data(
            contentsOf: source.url.appendingPathComponent("machine-identifier.bin")
        )
        #expect(cloneData != sourceData,
                "Machine identifier MUST differ — reusing causes undefined behavior")
    }

    @Test("Clone can be loaded back as a valid VirtualMachineBundle")
    func cloneIsLoadable() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        _ = try CloneManager.clone(source: source, to: destURL)

        let loaded = try VirtualMachineBundle.load(from: destURL)
        #expect(loaded.spec == source.spec)
        #expect(loaded.metadata.id != source.metadata.id)
    }

    @Test("Throws alreadyExists when destination already exists")
    func throwsOnExistingDest() throws {
        let (source, tempDir) = try makeTestBundle()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destURL = tempDir.appendingPathComponent("clone.vm")
        _ = try CloneManager.clone(source: source, to: destURL)

        #expect {
            try CloneManager.clone(source: source, to: destURL)
        } throws: { error in
            guard let bundleError = error as? VirtualMachineBundleError else { return false }
            return bundleError == .alreadyExists(url: destURL)
        }
    }

    @Test("Skips missing source files without crashing")
    func skipsMissingFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a minimal bundle with NO disk.img or auxiliary.bin
        let sourceURL = tempDir.appendingPathComponent("sparse.vm")
        let source = try VirtualMachineBundle.create(at: sourceURL, spec: VirtualMachineSpecification())

        // Only write machine-identifier.bin (required for clone to write new one)
        try Data("fake-mid".utf8).write(
            to: sourceURL.appendingPathComponent("machine-identifier.bin")
        )

        let destURL = tempDir.appendingPathComponent("clone.vm")
        let clone = try CloneManager.clone(source: source, to: destURL)

        // Clone should succeed, just without the missing files.
        #expect(clone.spec == source.spec)
        #expect(!FileManager.default.fileExists(
            atPath: destURL.appendingPathComponent("disk.img").path
        ))
    }
}
