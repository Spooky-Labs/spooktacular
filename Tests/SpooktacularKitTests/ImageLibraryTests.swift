import Testing
import Foundation
@testable import SpooktacularKit

@Suite("ImageLibrary")
struct ImageLibraryTests {

    /// Creates a fresh temporary directory for each test.
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    @Test("Starts empty")
    func startsEmpty() {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = ImageLibrary(directory: dir)
        library.load()
        #expect(library.images.isEmpty)
    }

    @Test("Adds and persists an IPSW image")
    func addsAndPersistsIPSW() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a small temp file to act as the IPSW.
        let fm = FileManager.default
        let ipswDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: ipswDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ipswDir) }

        let ipswURL = ipswDir.appendingPathComponent("test.ipsw")
        try Data("fake-ipsw-content".utf8).write(to: ipswURL)

        let library = ImageLibrary(directory: dir)
        library.load()

        try library.addIPSW(at: ipswURL, name: "macOS 15.4")

        #expect(library.images.count == 1)
        #expect(library.images[0].name == "macOS 15.4")

        if case .ipsw(let path) = library.images[0].source {
            #expect(path.hasSuffix("test.ipsw"))
            #expect(fm.fileExists(atPath: path))
        } else {
            Issue.record("Expected .ipsw source")
        }

        // Verify persistence: the file was copied into the library directory.
        let copiedPath = dir.appendingPathComponent("test.ipsw").path
        #expect(fm.fileExists(atPath: copiedPath))

        // Verify size was captured.
        #expect(library.images[0].sizeInBytes != nil)
    }

    @Test("Adds an OCI image reference")
    func addsOCIImage() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = ImageLibrary(directory: dir)
        library.load()

        try library.addOCI(reference: "ghcr.io/spooktacular/macos:15.4", name: "OCI macOS 15.4")

        #expect(library.images.count == 1)
        #expect(library.images[0].name == "OCI macOS 15.4")

        if case .oci(let ref) = library.images[0].source {
            #expect(ref == "ghcr.io/spooktacular/macos:15.4")
        } else {
            Issue.record("Expected .oci source")
        }

        #expect(library.images[0].sizeInBytes == nil)
    }

    @Test("Removes an image by ID")
    func removesImageByID() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = ImageLibrary(directory: dir)
        library.load()

        try library.addOCI(reference: "ref1", name: "Image A")
        try library.addOCI(reference: "ref2", name: "Image B")
        #expect(library.images.count == 2)

        let idToRemove = library.images[0].id
        try library.remove(id: idToRemove)

        #expect(library.images.count == 1)
        #expect(library.images[0].name == "Image B")
    }

    @Test("Round-trips through save and load")
    func roundTrips() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Populate a library and save it.
        let library = ImageLibrary(directory: dir)
        library.load()

        try library.addOCI(reference: "ghcr.io/example:latest", name: "Example")

        let savedImage = library.images[0]

        // Load into a fresh instance.
        let library2 = ImageLibrary(directory: dir)
        library2.load()

        #expect(library2.images.count == 1)
        #expect(library2.images[0].id == savedImage.id)
        #expect(library2.images[0].name == savedImage.name)
        #expect(library2.images[0].source == savedImage.source)
        // ISO 8601 may truncate sub-second precision.
        #expect(
            abs(library2.images[0].addedAt.timeIntervalSince(savedImage.addedAt)) < 1.0,
            "addedAt must survive round-trip"
        )
    }

    @Test("Handles missing library directory gracefully")
    func handlesMissingDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deeply")
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: dir) }

        // The directory does not exist yet.
        let library = ImageLibrary(directory: dir)
        library.load()

        // Should start empty without crashing.
        #expect(library.images.isEmpty)

        // The directory should now exist (created by load).
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
