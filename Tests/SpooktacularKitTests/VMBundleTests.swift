import Testing
import Foundation
@testable import SpooktacularKit

@Suite("VMBundle")
struct VMBundleTests {

    // MARK: - VMSpec Defaults and Clamping

    @Suite("VMSpec defaults and clamping")
    struct VMSpecDefaultsTests {

        @Test("Default spec has expected values")
        func defaultValues() {
            let spec = VMSpec()
            #expect(spec.cpuCount == 4)
            #expect(spec.memorySizeInBytes == 8 * 1024 * 1024 * 1024)
            #expect(spec.diskSizeInBytes == 64 * 1024 * 1024 * 1024)
            #expect(spec.displayCount == 1)
            #expect(spec.networkMode == .nat)
        }

        @Test("Respects the 4-CPU minimum for macOS VMs")
        func minimumCPUCount() {
            let spec = VMSpec(cpuCount: 2)
            #expect(spec.cpuCount == 4)
        }

        @Test("CPU count at exactly the minimum passes through")
        func cpuCountAtMinimum() {
            let spec = VMSpec(cpuCount: 4)
            #expect(spec.cpuCount == 4)
        }

        @Test("CPU count above minimum passes through unchanged")
        func cpuCountAboveMinimum() {
            let spec = VMSpec(cpuCount: 12)
            #expect(spec.cpuCount == 12)
        }

        @Test("Display count is clamped to minimum of 1")
        func displayCountFloor() {
            let spec = VMSpec(displayCount: 0)
            #expect(spec.displayCount == 1)
        }

        @Test("Display count is clamped to maximum of 2")
        func displayCountCeiling() {
            let spec = VMSpec(displayCount: 5)
            #expect(spec.displayCount == 2)
        }

        @Test("Negative display count is clamped to 1")
        func negativeDisplayCount() {
            let spec = VMSpec(displayCount: -1)
            #expect(spec.displayCount == 1)
        }

        @Test("Two specs with identical parameters are equal")
        func equatable() {
            let a = VMSpec(cpuCount: 6, memorySizeInBytes: 8_000_000_000)
            let b = VMSpec(cpuCount: 6, memorySizeInBytes: 8_000_000_000)
            #expect(a == b)
        }

        @Test("Two specs with different parameters are not equal")
        func notEquatable() {
            let a = VMSpec(cpuCount: 6)
            let b = VMSpec(cpuCount: 8)
            #expect(a != b)
        }

        @Test("Default spec has audio enabled")
        func defaultAudioEnabled() {
            let spec = VMSpec()
            #expect(spec.audioEnabled == true)
        }

        @Test("Default spec has microphone disabled")
        func defaultMicrophoneDisabled() {
            let spec = VMSpec()
            #expect(spec.microphoneEnabled == false)
        }

        @Test("Default spec has no shared folders")
        func defaultNoSharedFolders() {
            let spec = VMSpec()
            #expect(spec.sharedFolders.isEmpty)
        }

        @Test("Default spec has no custom MAC address")
        func defaultNoMacAddress() {
            let spec = VMSpec()
            #expect(spec.macAddress == nil)
        }

        @Test("Default spec has auto-resize enabled")
        func defaultAutoResizeEnabled() {
            let spec = VMSpec()
            #expect(spec.autoResizeDisplay == true)
        }

        @Test("Default spec has clipboard sharing enabled")
        func defaultClipboardSharingEnabled() {
            let spec = VMSpec()
            #expect(spec.clipboardSharingEnabled == true)
        }
    }

    // MARK: - SharedFolder

    @Suite("SharedFolder")
    struct SharedFolderTests {

        @Test("Round-trips through JSON")
        func jsonRoundTrip() throws {
            let folder = SharedFolder(
                hostPath: "/Users/test/shared",
                tag: "myshare",
                readOnly: true
            )
            let data = try VMBundle.encoder.encode(folder)
            let decoded = try VMBundle.decoder.decode(SharedFolder.self, from: data)
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

    // MARK: - VMSpec Serialization

    @Suite("VMSpec JSON round-trip")
    struct VMSpecSerializationTests {

        @Test("Round-trips a default spec through VMBundle's encoder")
        func defaultSpecRoundTrip() throws {
            let spec = VMSpec()

            let data = try VMBundle.encoder.encode(spec)
            let decoded = try VMBundle.decoder.decode(VMSpec.self, from: data)

            #expect(decoded == spec)
        }

        @Test("Round-trips custom spec values")
        func customSpecValues() throws {
            let spec = VMSpec(
                cpuCount: 8,
                memorySizeInBytes: 16 * 1024 * 1024 * 1024,
                diskSizeInBytes: 100 * 1024 * 1024 * 1024,
                displayCount: 2,
                networkMode: .bridged(interface: "en0")
            )

            let data = try VMBundle.encoder.encode(spec)
            let decoded = try VMBundle.decoder.decode(VMSpec.self, from: data)

            #expect(decoded == spec)
        }

        @Test(
            "Round-trips each network mode",
            arguments: [
                NetworkMode.nat,
                .bridged(interface: "en0"),
                .isolated,
                .hostOnly,
            ]
        )
        func networkModeRoundTrip(mode: NetworkMode) throws {
            let spec = VMSpec(networkMode: mode)
            let data = try VMBundle.encoder.encode(spec)
            let decoded = try VMBundle.decoder.decode(VMSpec.self, from: data)
            #expect(decoded.networkMode == mode)
        }
    }

    // MARK: - VMMetadata Serialization

    @Suite("VMMetadata")
    struct VMMetadataTests {

        @Test("Generates a unique ID on creation")
        func uniqueID() {
            let a = VMMetadata()
            let b = VMMetadata()
            #expect(a.id != b.id)
        }

        @Test("Records creation date")
        func creationDate() {
            let before = Date()
            let metadata = VMMetadata()
            let after = Date()

            #expect(metadata.createdAt >= before)
            #expect(metadata.createdAt <= after)
        }

        @Test("Defaults setupCompleted to false and lastBootedAt to nil")
        func defaults() {
            let metadata = VMMetadata()
            #expect(metadata.setupCompleted == false)
            #expect(metadata.lastBootedAt == nil)
        }

        @Test("Round-trips all fields through VMBundle's encoder including createdAt")
        func fullRoundTrip() throws {
            var metadata = VMMetadata()
            metadata.setupCompleted = true
            metadata.lastBootedAt = Date()

            let data = try VMBundle.encoder.encode(metadata)
            let decoded = try VMBundle.decoder.decode(VMMetadata.self, from: data)

            #expect(decoded.id == metadata.id)
            #expect(decoded.setupCompleted == true)
            #expect(decoded.lastBootedAt != nil)
            // ISO 8601 truncates to seconds, so compare within 1s.
            #expect(
                abs(decoded.createdAt.timeIntervalSince(metadata.createdAt)) < 1.0,
                "createdAt must survive round-trip"
            )
            #expect(
                abs(decoded.lastBootedAt!.timeIntervalSince(metadata.lastBootedAt!)) < 1.0,
                "lastBootedAt must survive round-trip"
            )
        }

        @Test("Tracks setup completion state")
        func setupCompletion() {
            var metadata = VMMetadata()
            #expect(metadata.setupCompleted == false)

            metadata.setupCompleted = true
            #expect(metadata.setupCompleted == true)
        }
    }

    // MARK: - Bundle Directory Operations

    @Suite("Bundle directory operations")
    struct BundleDirectoryTests {

        /// Creates a temporary directory for a test. Cleaned up by the caller.
        private func makeTempDir() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        }

        @Test("Creates a bundle directory at the specified path")
        func createBundle() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            let bundle = try VMBundle.create(at: bundleURL, spec: VMSpec())

            #expect(FileManager.default.fileExists(atPath: bundleURL.path))
            #expect(bundle.url == bundleURL)
            #expect(bundle.spec.cpuCount == 4)
        }

        @Test("Writes config.json readable by VMBundle.decoder")
        func writesValidConfig() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            let spec = VMSpec(cpuCount: 8, memorySizeInBytes: 16_000_000_000)
            _ = try VMBundle.create(at: bundleURL, spec: spec)

            let data = try Data(contentsOf: bundleURL.appendingPathComponent("config.json"))
            let decoded = try VMBundle.decoder.decode(VMSpec.self, from: data)
            #expect(decoded == spec)
        }

        @Test("Writes metadata.json to the bundle directory")
        func writesMetadata() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            _ = try VMBundle.create(at: bundleURL, spec: VMSpec())

            let metadataURL = bundleURL.appendingPathComponent("metadata.json")
            #expect(FileManager.default.fileExists(atPath: metadataURL.path))

            let data = try Data(contentsOf: metadataURL)
            let decoded = try VMBundle.decoder.decode(VMMetadata.self, from: data)
            #expect(decoded.setupCompleted == false)
        }

        @Test("Loads an existing bundle from disk with matching spec and metadata")
        func loadBundle() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            let original = try VMBundle.create(
                at: bundleURL,
                spec: VMSpec(cpuCount: 6)
            )

            let loaded = try VMBundle.load(from: bundleURL)
            #expect(loaded.spec == original.spec)
            #expect(loaded.metadata.id == original.metadata.id)
        }

        @Test("writeMetadata persists and can be reloaded")
        func writeMetadataRoundTrip() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            let bundle = try VMBundle.create(at: bundleURL, spec: VMSpec())
            #expect(bundle.metadata.setupCompleted == false)

            var updated = bundle.metadata
            updated.setupCompleted = true
            try VMBundle.writeMetadata(updated, to: bundleURL)

            let reloaded = try VMBundle.load(from: bundleURL)
            #expect(reloaded.metadata.setupCompleted == true)
            #expect(reloaded.metadata.id == bundle.metadata.id)
        }

        @Test("Throws notFound when loading a nonexistent bundle")
        func loadNonexistent() {
            let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).vm")
            #expect {
                try VMBundle.load(from: bogus)
            } throws: { error in
                guard let bundleError = error as? VMBundleError else { return false }
                return bundleError == .notFound(url: bogus)
            }
        }

        @Test("Throws invalidConfiguration when config.json is corrupt")
        func loadCorruptConfig() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            _ = try VMBundle.create(at: bundleURL, spec: VMSpec())

            // Corrupt config.json
            try Data("not-json".utf8).write(
                to: bundleURL.appendingPathComponent("config.json")
            )

            #expect {
                try VMBundle.load(from: bundleURL)
            } throws: { error in
                guard let bundleError = error as? VMBundleError else { return false }
                return bundleError == .invalidConfiguration(url: bundleURL)
            }
        }

        @Test("Throws invalidMetadata when metadata.json is corrupt")
        func loadCorruptMetadata() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            _ = try VMBundle.create(at: bundleURL, spec: VMSpec())

            // Corrupt metadata.json
            try Data("not-json".utf8).write(
                to: bundleURL.appendingPathComponent("metadata.json")
            )

            #expect {
                try VMBundle.load(from: bundleURL)
            } throws: { error in
                guard let bundleError = error as? VMBundleError else { return false }
                return bundleError == .invalidMetadata(url: bundleURL)
            }
        }

        @Test("Throws alreadyExists when creating at an existing path")
        func createAtExistingPath() throws {
            let tempDir = makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let bundleURL = tempDir.appendingPathComponent("test.vm")
            _ = try VMBundle.create(at: bundleURL, spec: VMSpec())

            #expect {
                try VMBundle.create(at: bundleURL, spec: VMSpec())
            } throws: { error in
                guard let bundleError = error as? VMBundleError else { return false }
                return bundleError == .alreadyExists(url: bundleURL)
            }
        }
    }
}
