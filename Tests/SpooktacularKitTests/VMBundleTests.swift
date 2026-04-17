import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("VirtualMachineBundle", .tags(.lifecycle))
struct VirtualMachineBundleTests {

    // MARK: - VirtualMachineSpecification Defaults and Clamping

    @Suite("Specification defaults and clamping", .tags(.lifecycle))
    struct SpecDefaultsTests {

        @Test("Default spec has expected values")
        func defaultValues() {
            let spec = VirtualMachineSpecification()
            #expect(spec.cpuCount == 4)
            #expect(spec.memorySizeInBytes == 8 * 1024 * 1024 * 1024)
            #expect(spec.diskSizeInBytes == 64 * 1024 * 1024 * 1024)
            #expect(spec.displayCount == 1)
            #expect(spec.networkMode == .nat)
            #expect(spec.audioEnabled == true)
            #expect(spec.microphoneEnabled == false)
            #expect(spec.sharedFolders.isEmpty)
            #expect(spec.macAddress == nil)
            #expect(spec.autoResizeDisplay == true)
            #expect(spec.clipboardSharingEnabled == true)
        }

        @Test(
            "CPU count is clamped to minimum of 4",
            arguments: [
                (2, 4),
                (4, 4),
                (12, 12),
            ]
        )
        func cpuCountClamping(input: Int, expected: Int) {
            let spec = VirtualMachineSpecification(cpuCount: input)
            #expect(spec.cpuCount == expected)
        }

        @Test(
            "Display count is clamped to 1...2",
            arguments: [
                (-1, 1),
                (0, 1),
                (1, 1),
                (2, 2),
                (5, 2),
            ]
        )
        func displayCountClamping(input: Int, expected: Int) {
            let spec = VirtualMachineSpecification(displayCount: input)
            #expect(spec.displayCount == expected)
        }

        @Test("Two specs with identical parameters are equal")
        func equatable() {
            let a = VirtualMachineSpecification(cpuCount: 6, memorySizeInBytes: 8_000_000_000)
            let b = VirtualMachineSpecification(cpuCount: 6, memorySizeInBytes: 8_000_000_000)
            #expect(a == b)
        }

        @Test("Two specs with different parameters are not equal")
        func notEquatable() {
            let a = VirtualMachineSpecification(cpuCount: 6)
            let b = VirtualMachineSpecification(cpuCount: 8)
            #expect(a != b)
        }

        @Test("with() overrides only specified fields")
        func withOverrides() {
            let original = VirtualMachineSpecification(cpuCount: 4, memorySizeInBytes: .gigabytes(8))
            let modified = original.with(cpuCount: 12)
            #expect(modified.cpuCount == 12)
            #expect(modified.memorySizeInBytes == original.memorySizeInBytes)
            #expect(modified.diskSizeInBytes == original.diskSizeInBytes)
            #expect(modified.networkMode == original.networkMode)
        }

        @Test("with(macAddress: .clear) clears MAC address")
        func withClearsMACAddress() {
            let original = VirtualMachineSpecification(macAddress: MACAddress("aa:bb:cc:dd:ee:ff"))
            let cleared = original.with(macAddress: .clear)
            #expect(cleared.macAddress == nil)
        }

        @Test("with(macAddress: .set(...)) updates the MAC address")
        func withSetsMACAddress() throws {
            let original = VirtualMachineSpecification()
            let address = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
            let updated = original.with(macAddress: .set(address))
            #expect(updated.macAddress == address)
        }

        @Test("with(macAddress: .omit) preserves the existing MAC address")
        func withOmitPreservesMACAddress() throws {
            let address = try #require(MACAddress("aa:bb:cc:dd:ee:ff"))
            let original = VirtualMachineSpecification(macAddress: address)
            let unchanged = original.with(cpuCount: 8)
            #expect(unchanged.macAddress == address)
        }
    }

    // MARK: - Spec validation

    @Suite("Specification validation", .tags(.lifecycle))
    struct SpecValidationTests {

        @Test("Default spec passes validation")
        func defaultPasses() {
            let spec = VirtualMachineSpecification()
            #expect(throws: Never.self) { try spec.validate() }
        }

        @Test("Memory below 1 GiB fails validation")
        func memoryTooLow() {
            let spec = VirtualMachineSpecification(memorySizeInBytes: 500 * 1024 * 1024)
            #expect(throws: VirtualMachineSpecificationError.self) {
                try spec.validate()
            }
        }

        @Test("Memory at or above 1 TiB fails validation (catches unit bugs)")
        func memoryTooHigh() {
            let spec = VirtualMachineSpecification(memorySizeInBytes: 2 * (1 << 40))
            #expect(throws: VirtualMachineSpecificationError.self) {
                try spec.validate()
            }
        }

        @Test("Disk below 1 GiB fails validation")
        func diskTooSmall() {
            let spec = VirtualMachineSpecification(diskSizeInBytes: 100 * 1024 * 1024)
            #expect(throws: VirtualMachineSpecificationError.self) {
                try spec.validate()
            }
        }
    }

    // MARK: - SharedFolder

    @Suite("SharedFolder", .tags(.lifecycle))
    struct SharedFolderTests {

        @Test("Round-trips through JSON")
        func jsonRoundTrip() throws {
            let folder = SharedFolder(
                hostPath: "/Users/test/shared",
                tag: "myshare",
                readOnly: true
            )
            let data = try VirtualMachineBundle.encoder.encode(folder)
            let decoded = try VirtualMachineBundle.decoder.decode(SharedFolder.self, from: data)
            #expect(decoded == folder)
        }

        @Test("Read-only defaults to false")
        func readOnlyDefault() {
            let folder = SharedFolder(hostPath: "/tmp/share", tag: "tag")
            #expect(folder.readOnly == false)
        }

        @Test("Two folders with same values are equal")
        func equality() {
            let a = SharedFolder(hostPath: "/tmp", tag: "t", readOnly: true)
            let b = SharedFolder(hostPath: "/tmp", tag: "t", readOnly: true)
            #expect(a == b)
        }
    }

    // MARK: - Specification Serialization

    @Suite("Specification JSON round-trip", .tags(.lifecycle))
    struct SpecSerializationTests {

        @Test("Round-trips a default spec")
        func defaultSpecRoundTrip() throws {
            let spec = VirtualMachineSpecification()
            let data = try VirtualMachineBundle.encoder.encode(spec)
            let decoded = try VirtualMachineBundle.decoder.decode(VirtualMachineSpecification.self, from: data)
            #expect(decoded == spec)
        }

        @Test("Round-trips custom spec values")
        func customSpecValues() throws {
            let spec = VirtualMachineSpecification(
                cpuCount: 8,
                memorySizeInBytes: 16 * 1024 * 1024 * 1024,
                diskSizeInBytes: 100 * 1024 * 1024 * 1024,
                displayCount: 2,
                networkMode: .bridged(interface: "en0")
            )
            let data = try VirtualMachineBundle.encoder.encode(spec)
            let decoded = try VirtualMachineBundle.decoder.decode(VirtualMachineSpecification.self, from: data)
            #expect(decoded == spec)
        }

        @Test(
            "Round-trips each network mode",
            arguments: [
                NetworkMode.nat,
                .bridged(interface: "en0"),
                .isolated,
            ]
        )
        func networkModeRoundTrip(mode: NetworkMode) throws {
            let spec = VirtualMachineSpecification(networkMode: mode)
            let data = try VirtualMachineBundle.encoder.encode(spec)
            let decoded = try VirtualMachineBundle.decoder.decode(VirtualMachineSpecification.self, from: data)
            #expect(decoded.networkMode == mode)
        }
    }

    // MARK: - Metadata

    @Suite("Metadata", .tags(.lifecycle))
    struct MetadataTests {

        @Test("Generates a unique ID on creation")
        func uniqueID() {
            let a = VirtualMachineMetadata()
            let b = VirtualMachineMetadata()
            #expect(a.id != b.id)
        }

        @Test("Records creation date within current time window")
        func creationDate() {
            let before = Date()
            let metadata = VirtualMachineMetadata()
            let after = Date()
            #expect(metadata.createdAt >= before)
            #expect(metadata.createdAt <= after)
        }

        @Test("Defaults setupCompleted to false and lastBootedAt to nil")
        func defaults() {
            let metadata = VirtualMachineMetadata()
            #expect(metadata.setupCompleted == false)
            #expect(metadata.lastBootedAt == nil)
        }

        @Test("Round-trips all fields through encoder")
        func fullRoundTrip() throws {
            var metadata = VirtualMachineMetadata()
            metadata.setupCompleted = true
            metadata.lastBootedAt = Date()

            let data = try VirtualMachineBundle.encoder.encode(metadata)
            let decoded = try VirtualMachineBundle.decoder.decode(VirtualMachineMetadata.self, from: data)

            #expect(decoded.id == metadata.id)
            #expect(decoded.setupCompleted == true)
            let lastBooted = try #require(decoded.lastBootedAt)
            #expect(
                abs(decoded.createdAt.timeIntervalSince(metadata.createdAt)) < 1.0,
                "createdAt must survive round-trip"
            )
            #expect(
                abs(lastBooted.timeIntervalSince(metadata.lastBootedAt!)) < 1.0,
                "lastBootedAt must survive round-trip"
            )
        }

        @Test("Tracks setup completion state")
        func setupCompletion() {
            var metadata = VirtualMachineMetadata()
            #expect(metadata.setupCompleted == false)
            metadata.setupCompleted = true
            #expect(metadata.setupCompleted == true)
        }
    }

    // MARK: - Bundle Directory Operations

    @Suite("Bundle directory operations", .tags(.lifecycle))
    struct BundleDirectoryTests {

        @Test("Creates a bundle directory at the specified path", .timeLimit(.minutes(1)))
        func createBundle() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())

            #expect(FileManager.default.fileExists(atPath: bundleURL.path))
            #expect(bundle.url == bundleURL)
            #expect(bundle.spec.cpuCount == 4)
        }

        @Test("Writes config.json readable by decoder", .timeLimit(.minutes(1)))
        func writesValidConfig() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            let spec = VirtualMachineSpecification(cpuCount: 8, memorySizeInBytes: 16_000_000_000)
            _ = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

            let data = try Data(contentsOf: bundleURL.appendingPathComponent("config.json"))
            let decoded = try VirtualMachineBundle.decoder.decode(VirtualMachineSpecification.self, from: data)
            #expect(decoded == spec)
        }

        @Test("Writes metadata.json to the bundle directory", .timeLimit(.minutes(1)))
        func writesMetadata() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            _ = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())

            let metadataURL = bundleURL.appendingPathComponent("metadata.json")
            try #require(
                FileManager.default.fileExists(atPath: metadataURL.path),
                "metadata.json must exist"
            )
            let data = try Data(contentsOf: metadataURL)
            let decoded = try VirtualMachineBundle.decoder.decode(VirtualMachineMetadata.self, from: data)
            #expect(decoded.setupCompleted == false)
        }

        @Test("Loads an existing bundle from disk with matching spec and metadata", .timeLimit(.minutes(1)))
        func loadBundle() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            let original = try VirtualMachineBundle.create(
                at: bundleURL,
                spec: VirtualMachineSpecification(cpuCount: 6)
            )

            let loaded = try VirtualMachineBundle.load(from: bundleURL)
            #expect(loaded.spec == original.spec)
            #expect(loaded.metadata.id == original.metadata.id)
        }

        @Test("writeMetadata persists and can be reloaded", .timeLimit(.minutes(1)))
        func writeMetadataRoundTrip() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())
            try #require(bundle.metadata.setupCompleted == false)

            var updated = bundle.metadata
            updated.setupCompleted = true
            try VirtualMachineBundle.writeMetadata(updated, to: bundleURL)

            let reloaded = try VirtualMachineBundle.load(from: bundleURL)
            #expect(reloaded.metadata.setupCompleted == true)
            #expect(reloaded.metadata.id == bundle.metadata.id)
        }

        @Test("writeSpec persists and reloads correctly", .timeLimit(.minutes(1)))
        func writeSpecRoundTrip() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            let originalSpec = VirtualMachineSpecification(cpuCount: 4, memorySizeInBytes: 8 * 1024 * 1024 * 1024)
            let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: originalSpec)
            try #require(bundle.spec.cpuCount == 4)

            let updatedSpec = VirtualMachineSpecification(
                cpuCount: 12,
                memorySizeInBytes: 32 * 1024 * 1024 * 1024,
                diskSizeInBytes: 128 * 1024 * 1024 * 1024,
                displayCount: 2,
                networkMode: .bridged(interface: "en0")
            )
            try VirtualMachineBundle.writeSpec(updatedSpec, to: bundleURL)

            let reloaded = try VirtualMachineBundle.load(from: bundleURL)
            #expect(reloaded.spec == updatedSpec)
            #expect(reloaded.metadata.id == bundle.metadata.id)
        }
    }

    // MARK: - Error Cases

    @Suite("Error cases", .tags(.lifecycle))
    struct ErrorCaseTests {

        @Test("Throws notFound when loading a nonexistent bundle", .timeLimit(.minutes(1)))
        func loadNonexistent() {
            let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).vm")
            #expect {
                try VirtualMachineBundle.load(from: bogus)
            } throws: { error in
                guard let bundleError = error as? VirtualMachineBundleError else { return false }
                return bundleError == .notFound(url: bogus)
            }
        }

        @Test("Throws invalidConfiguration when config.json is corrupt", .timeLimit(.minutes(1)))
        func loadCorruptConfig() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            _ = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())

            try Data("not-json".utf8).write(
                to: bundleURL.appendingPathComponent("config.json")
            )

            #expect {
                try VirtualMachineBundle.load(from: bundleURL)
            } throws: { error in
                guard let bundleError = error as? VirtualMachineBundleError else { return false }
                return bundleError == .invalidConfiguration(url: bundleURL)
            }
        }

        @Test("Throws invalidMetadata when metadata.json is corrupt", .timeLimit(.minutes(1)))
        func loadCorruptMetadata() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            _ = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())

            try Data("not-json".utf8).write(
                to: bundleURL.appendingPathComponent("metadata.json")
            )

            #expect {
                try VirtualMachineBundle.load(from: bundleURL)
            } throws: { error in
                guard let bundleError = error as? VirtualMachineBundleError else { return false }
                return bundleError == .invalidMetadata(url: bundleURL)
            }
        }

        @Test("Throws alreadyExists when creating at an existing path", .timeLimit(.minutes(1)))
        func createAtExistingPath() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            _ = try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())

            #expect {
                try VirtualMachineBundle.create(at: bundleURL, spec: VirtualMachineSpecification())
            } throws: { error in
                guard let bundleError = error as? VirtualMachineBundleError else { return false }
                return bundleError == .alreadyExists(url: bundleURL)
            }
        }
    }
}
