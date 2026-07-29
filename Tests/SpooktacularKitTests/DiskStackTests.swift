import Testing
import Foundation
import Virtualization
@testable import SpooktacularInfrastructureApple

@Suite("DiskStack", .tags(.infrastructure))
struct DiskStackTests {

    /// 2 GiB is large enough to be a realistic image and small enough
    /// that ASIF sparseness keeps it at a few megabytes on disk.
    private static let size: UInt64 = 2 * 1024 * 1024 * 1024

    @available(macOS 27, *)
    @Test("creates a sparse ASIF base and reports its layer UUID")
    func createsBase() throws {
        let temp = TempDirectory()
        let baseURL = temp.file("base.asif")

        let layerUUID = try DiskStack.createBase(at: baseURL, sizeInBytes: Self.size)

        #expect(FileManager.default.fileExists(atPath: baseURL.path))
        #expect(try DiskStack.baseLayerUUID(at: baseURL) == layerUUID)

        // Sparse: a 2 GiB image must not consume 2 GiB.
        let attributes = try FileManager.default.attributesOfItem(atPath: baseURL.path)
        let bytes = try #require(attributes[.size] as? Int)
        #expect(bytes < 64 * 1024 * 1024)
    }

    @available(macOS 27, *)
    @Test("overlay is created against the base and inherits its size")
    func createsOverlay() throws {
        let temp = TempDirectory()
        let baseURL = temp.file("base.asif")
        let overlayURL = temp.file("overlay.asif")
        _ = try DiskStack.createBase(at: baseURL, sizeInBytes: Self.size)

        try DiskStack.createOverlay(at: overlayURL, base: baseURL, sizeInBytes: nil)

        #expect(FileManager.default.fileExists(atPath: overlayURL.path))
    }

    @available(macOS 27, *)
    @Test("attachment builds from base plus overlay")
    func buildsAttachment() throws {
        let temp = TempDirectory()
        let baseURL = temp.file("base.asif")
        let overlayURL = temp.file("overlay.asif")
        let layerUUID = try DiskStack.createBase(at: baseURL, sizeInBytes: Self.size)
        try DiskStack.createOverlay(at: overlayURL, base: baseURL, sizeInBytes: nil)

        let attachment = try DiskStack.attachment(
            base: baseURL,
            overlay: overlayURL,
            expectedBaseLayerUUID: layerUUID
        )
        #expect(attachment.url.lastPathComponent == overlayURL.lastPathComponent)
    }

    @available(macOS 27, *)
    @Test("attachment rejects a base whose layer UUID drifted")
    func detectsDrift() throws {
        let temp = TempDirectory()
        let baseURL = temp.file("base.asif")
        let overlayURL = temp.file("overlay.asif")
        let real = try DiskStack.createBase(at: baseURL, sizeInBytes: Self.size)
        try DiskStack.createOverlay(at: overlayURL, base: baseURL, sizeInBytes: nil)

        let bogus = UUID()
        #expect(throws: DiskStackError.baseDrift(expected: bogus, found: real)) {
            try DiskStack.attachment(base: baseURL, overlay: overlayURL, expectedBaseLayerUUID: bogus)
        }
    }

    @available(macOS 27, *)
    @Test("an explicitly sized overlay resizes the stack beyond the base")
    func overlayResizesStack() throws {
        let temp = TempDirectory()
        let baseURL = temp.file("base.asif")
        let overlayURL = temp.file("overlay.asif")
        _ = try DiskStack.createBase(at: baseURL, sizeInBytes: Self.size)

        let larger = Self.size * 2
        try DiskStack.createOverlay(at: overlayURL, base: baseURL, sizeInBytes: larger)

        #expect(FileManager.default.fileExists(atPath: overlayURL.path))
    }
}
