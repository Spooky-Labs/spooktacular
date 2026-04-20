import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("CloneManager", .tags(.infrastructure))
struct CloneManagerTests {

    /// Creates a temporary bundle with a fake disk image for testing.
    private func makeTestBundle(in tmp: TempDirectory) throws -> VirtualMachineBundle {
        let bundleURL = tmp.url.appendingPathComponent("source.vm")
        let bundle = try VirtualMachineBundle.create(
            at: bundleURL,
            spec: VirtualMachineSpecification(cpuCount: 6)
        )

        for (name, content) in [
            ("disk.img", "fake-disk-content"),
            ("auxiliary.bin", "fake-aux-content"),
            ("hardware-model.bin", "fake-hardware-model"),
            ("machine-identifier.bin", "original-machine-id"),
        ] {
            try Data(content.utf8).write(to: bundleURL.appendingPathComponent(name))
        }

        return bundle
    }

    // MARK: - Clone Creation

    @Suite("Successful clone", .tags(.infrastructure))
    struct SuccessfulCloneTests {

        private func setup() throws -> (source: VirtualMachineBundle, clone: VirtualMachineBundle, tmp: TempDirectory) {
            let tmp = TempDirectory()
            let outer = CloneManagerTests()
            let source = try outer.makeTestBundle(in: tmp)
            let destURL = tmp.url.appendingPathComponent("clone.vm")
            let clone = try CloneManager.clone(source: source, to: destURL)
            return (source, clone, tmp)
        }

        @Test("Creates a new bundle directory for the clone", .timeLimit(.minutes(1)))
        func createsDirectory() throws {
            let (_, clone, tmp) = try setup()
            withExtendedLifetime(tmp) {
                #expect(FileManager.default.fileExists(atPath: clone.url.path))
            }
        }

        @Test("Preserves the spec from the source bundle", .timeLimit(.minutes(1)))
        func preservesSpec() throws {
            let (source, clone, _tmp) = try setup()
            #expect(clone.spec.cpuCount == source.spec.cpuCount)
            #expect(clone.spec.memorySizeInBytes == source.spec.memorySizeInBytes)
            #expect(clone.spec.networkMode == source.spec.networkMode)
        }

        @Test("Generates a new unique metadata ID", .timeLimit(.minutes(1)))
        func newMetadataID() throws {
            let (source, clone, _tmp) = try setup()
            #expect(clone.metadata.id != source.metadata.id)
        }

        @Test("Regenerates the MAC address on clone (prevents link-layer collision between siblings)", .timeLimit(.minutes(1)))
        func regeneratesMAC() throws {
            let (source, clone, _tmp) = try setup()
            // A clone must not share its MAC with the source
            // — two simultaneously-running siblings would fight
            // for the same DHCP lease on the host bridge. This
            // is the invariant CI regression-guards.
            #expect(clone.spec.macAddress != nil)
            #expect(clone.spec.macAddress != source.spec.macAddress)
            // And the new MAC must be locally-administered
            // (first octet `02:…`) per RFC 7042 § 2.1.1 —
            // the LSB of the first octet set to 1 marks the
            // address as unicast, and bit 2 marks it as
            // locally administered.
            if let mac = clone.spec.macAddress {
                let firstByteHex = String(mac.description.prefix(2))
                let firstByte = UInt8(firstByteHex, radix: 16) ?? 0
                #expect(firstByte & 0b0000_0010 == 0b0000_0010,
                    "First octet must have locally-administered bit set")
                #expect(firstByte & 0b0000_0001 == 0,
                    "First octet must be unicast (low bit clear)")
            }
        }

        @Test("Clone can be loaded back as a valid VirtualMachineBundle", .timeLimit(.minutes(1)))
        func cloneIsLoadable() throws {
            let (source, clone, _tmp) = try setup()
            let loaded = try VirtualMachineBundle.load(from: clone.url)
            // Clone matches source on every axis except the
            // MAC address — which is deliberately regenerated
            // so two running clones don't collide at the link
            // layer. Compare field-by-field (minus MAC) instead
            // of asserting equality on the whole spec.
            #expect(loaded.spec.cpuCount == source.spec.cpuCount)
            #expect(loaded.spec.memorySizeInBytes == source.spec.memorySizeInBytes)
            #expect(loaded.spec.diskSizeInBytes == source.spec.diskSizeInBytes)
            #expect(loaded.spec.displayCount == source.spec.displayCount)
            #expect(loaded.spec.networkMode == source.spec.networkMode)
            #expect(loaded.spec.audioEnabled == source.spec.audioEnabled)
            #expect(loaded.spec.sharedFolders == source.spec.sharedFolders)
            #expect(loaded.spec.macAddress != nil)
            #expect(loaded.spec.macAddress != source.spec.macAddress)
            #expect(loaded.metadata.id != source.metadata.id)
        }
    }

    // MARK: - File Copying

    @Suite("File artifacts", .tags(.infrastructure))
    struct FileArtifactTests {

        private func setup() throws -> (source: VirtualMachineBundle, destURL: URL, tmp: TempDirectory) {
            let tmp = TempDirectory()
            let outer = CloneManagerTests()
            let source = try outer.makeTestBundle(in: tmp)
            let destURL = tmp.url.appendingPathComponent("clone.vm")
            _ = try CloneManager.clone(source: source, to: destURL)
            return (source, destURL, tmp)
        }

        @Test(
            "Copies required bundle artifacts",
            .timeLimit(.minutes(1)),
            arguments: ["disk.img", "auxiliary.bin", "hardware-model.bin"]
        )
        func copiesArtifact(filename: String) throws {
            let (_, destURL, _tmp) = try setup()
            #expect(FileManager.default.fileExists(
                atPath: destURL.appendingPathComponent(filename).path
            ))
        }

        @Test("Copies disk.img content faithfully", .timeLimit(.minutes(1)))
        func diskContent() throws {
            let (_, destURL, _tmp) = try setup()
            let content = try String(data: Data(contentsOf: destURL.appendingPathComponent("disk.img")), encoding: .utf8)
            #expect(content == "fake-disk-content")
        }

        @Test("Hardware model is identical to source", .timeLimit(.minutes(1)))
        func hardwareModelIdentical() throws {
            let (source, destURL, _tmp) = try setup()
            let cloneData = try Data(contentsOf: destURL.appendingPathComponent("hardware-model.bin"))
            let sourceData = try Data(contentsOf: source.url.appendingPathComponent("hardware-model.bin"))
            #expect(cloneData == sourceData, "Hardware model must be identical to source")
        }

        @Test("Writes a NEW machine identifier (not copied from source)", .timeLimit(.minutes(1)))
        func newMachineIdentifier() throws {
            let (source, destURL, _tmp) = try setup()
            let cloneMID = destURL.appendingPathComponent("machine-identifier.bin")
            let cloneData = try Data(contentsOf: cloneMID)
            let sourceData = try Data(contentsOf: source.url.appendingPathComponent("machine-identifier.bin"))
            #expect(
                cloneData != sourceData,
                "Machine identifier MUST differ -- reusing causes undefined behavior"
            )
        }
    }

    // MARK: - Setup Inheritance

    @Test("Inherits setupCompleted from the source", .timeLimit(.minutes(1)))
    func inheritsSetupCompleted() throws {
        let tmp = TempDirectory()
        let source = try makeTestBundle(in: tmp)

        var updatedMetadata = source.metadata
        updatedMetadata.setupCompleted = true
        try VirtualMachineBundle.writeMetadata(updatedMetadata, to: source.url)

        let destURL = tmp.url.appendingPathComponent("clone.vm")
        let clone = try CloneManager.clone(
            source: try VirtualMachineBundle.load(from: source.url),
            to: destURL
        )

        #expect(clone.metadata.setupCompleted == true)
    }

    // MARK: - Error Handling

    @Suite("Error handling", .tags(.infrastructure))
    struct ErrorHandlingTests {

        @Test("Throws alreadyExists when destination already exists", .timeLimit(.minutes(1)))
        func throwsOnExistingDest() throws {
            let tmp = TempDirectory()
            let outer = CloneManagerTests()
            let source = try outer.makeTestBundle(in: tmp)
            let destURL = tmp.url.appendingPathComponent("clone.vm")
            _ = try CloneManager.clone(source: source, to: destURL)

            #expect {
                try CloneManager.clone(source: source, to: destURL)
            } throws: { error in
                guard let bundleError = error as? VirtualMachineBundleError else { return false }
                return bundleError == .alreadyExists(url: destURL)
            }
        }

        @Test("Partial clone is cleaned up on failure", .timeLimit(.minutes(1)))
        func rollbackOnFailure() throws {
            let tmp = TempDirectory()
            let outer = CloneManagerTests()
            let source = try outer.makeTestBundle(in: tmp)

            // Make the source disk.img unreadable so copyItem fails.
            let diskURL = source.url.appendingPathComponent("disk.img")
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000],
                ofItemAtPath: diskURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: diskURL.path
                )
            }

            let destURL = tmp.url.appendingPathComponent("rollback-clone.vm")

            #expect(throws: Error.self) {
                try CloneManager.clone(source: source, to: destURL)
            }

            #expect(
                !FileManager.default.fileExists(atPath: destURL.path),
                "Destination must be cleaned up after a clone failure"
            )
        }

        @Test("Skips missing source files without crashing", .timeLimit(.minutes(1)))
        func skipsMissingFiles() throws {
            let tmp = TempDirectory()
            let sourceURL = tmp.url.appendingPathComponent("sparse.vm")
            let source = try VirtualMachineBundle.create(
                at: sourceURL,
                spec: VirtualMachineSpecification()
            )

            try Data("fake-mid".utf8).write(
                to: sourceURL.appendingPathComponent("machine-identifier.bin")
            )

            let destURL = tmp.url.appendingPathComponent("clone.vm")
            let clone = try CloneManager.clone(source: source, to: destURL)

            // Same field-by-field comparison as `cloneIsLoadable`.
            // The clone's MAC is regenerated; every other field
            // carries over.
            #expect(clone.spec.cpuCount == source.spec.cpuCount)
            #expect(clone.spec.memorySizeInBytes == source.spec.memorySizeInBytes)
            #expect(clone.spec.networkMode == source.spec.networkMode)
            #expect(clone.spec.macAddress != nil)
            #expect(clone.spec.macAddress != source.spec.macAddress)
            #expect(!FileManager.default.fileExists(
                atPath: destURL.appendingPathComponent("disk.img").path
            ))
        }
    }
}
