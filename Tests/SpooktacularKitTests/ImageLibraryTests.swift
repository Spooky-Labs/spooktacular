import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("ImageLibrary", .tags(.infrastructure))
@MainActor
struct ImageLibraryTests {

    // MARK: - IPSW

    @Test("Adds and persists an IPSW image with correct name and source", .timeLimit(.minutes(1)))
    func addsAndPersistsIPSW() throws {
        let dir = TempDirectory()
        let ipswDir = TempDirectory()

        let ipswURL = ipswDir.file("test.ipsw")
        try Data("fake-ipsw-content".utf8).write(to: ipswURL)

        let library = ImageLibrary(directory: dir.url)
        library.load()

        try library.addIPSW(at: ipswURL, name: "macOS 15.4")

        let image = try #require(library.images.first, "Library must contain the added image")
        #expect(image.name == "macOS 15.4")

        if case .ipsw(let path) = image.source {
            #expect(path.hasSuffix("test.ipsw"))
            #expect(FileManager.default.fileExists(atPath: path))
        } else {
            Issue.record("Expected .ipsw source")
        }

        // Verify the file was copied into the library directory.
        #expect(FileManager.default.fileExists(atPath: dir.file("test.ipsw").path))
        #expect(image.sizeInBytes != nil)
    }

    // MARK: - OCI

    @Test("Adds an OCI image reference", .timeLimit(.minutes(1)))
    func addsOCIImage() throws {
        let dir = TempDirectory()
        let library = ImageLibrary(directory: dir.url)
        library.load()

        try library.addOCI(reference: "ghcr.io/spooktacular/macos:15.4", name: "OCI macOS 15.4")

        let image = try #require(library.images.first)
        #expect(image.name == "OCI macOS 15.4")

        if case .oci(let ref) = image.source {
            #expect(ref == "ghcr.io/spooktacular/macos:15.4")
        } else {
            Issue.record("Expected .oci source")
        }

        #expect(image.sizeInBytes == nil)
    }

    // MARK: - Remove

    @Test("Removes an image by ID and retains the other", .timeLimit(.minutes(1)))
    func removesImageByID() throws {
        let dir = TempDirectory()
        let library = ImageLibrary(directory: dir.url)
        library.load()

        try library.addOCI(reference: "ref1", name: "Image A")
        try library.addOCI(reference: "ref2", name: "Image B")

        let idToRemove = try #require(library.images.first).id
        try library.remove(id: idToRemove)

        let remaining = try #require(library.images.first)
        #expect(remaining.name == "Image B")
    }

    // MARK: - Persistence

    @Test("Round-trips through save and load", .timeLimit(.minutes(1)))
    func roundTrips() throws {
        let dir = TempDirectory()

        let library = ImageLibrary(directory: dir.url)
        library.load()
        try library.addOCI(reference: "ghcr.io/example:latest", name: "Example")
        let savedImage = try #require(library.images.first)

        let library2 = ImageLibrary(directory: dir.url)
        library2.load()

        let loadedImage = try #require(library2.images.first)
        #expect(loadedImage.id == savedImage.id)
        #expect(loadedImage.name == savedImage.name)
        #expect(loadedImage.source == savedImage.source)
        #expect(
            abs(loadedImage.addedAt.timeIntervalSince(savedImage.addedAt)) < 1.0,
            "addedAt must survive round-trip"
        )
    }

    // MARK: - Missing Directory

    @Test("Handles missing library directory gracefully", .timeLimit(.minutes(1)))
    func handlesMissingDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("deeply")
            .appendingPathComponent("nested")
        defer { try? FileManager.default.removeItem(at: dir) }

        let library = ImageLibrary(directory: dir)
        library.load()

        #expect(library.images.isEmpty)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }
}
