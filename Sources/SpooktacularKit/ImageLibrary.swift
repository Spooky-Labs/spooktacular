import Foundation
import os

/// A cached VM image available for creating new virtual machines.
///
/// Images can be either local IPSW files or OCI references.
/// The library tracks which images are cached on disk and
/// available for instant VM creation.
public struct VMImage: Sendable, Codable, Equatable, Identifiable {

    /// Unique identifier for this image.
    public let id: UUID

    /// Human-readable display name.
    public let name: String

    /// The source type of this image.
    public let source: ImageSource

    /// File size in bytes (if known).
    public let sizeInBytes: UInt64?

    /// When this image was added to the library.
    public let addedAt: Date

    /// Creates a new image entry.
    public init(
        name: String,
        source: ImageSource,
        sizeInBytes: UInt64? = nil
    ) {
        self.id = UUID()
        self.name = name
        self.source = source
        self.sizeInBytes = sizeInBytes
        self.addedAt = Date()
    }
}

/// The source type for a VM image.
public enum ImageSource: Sendable, Codable, Equatable {
    /// A local IPSW restore image file.
    case ipsw(path: String)
    /// An OCI container image reference.
    case oci(reference: String)
}

/// Manages the local cache of VM images.
///
/// The image library stores metadata about cached IPSWs and
/// OCI images at `~/.spooktacular/images/library.json`. The
/// actual image files live alongside in the same directory.
///
/// ## Usage
///
/// ```swift
/// let library = ImageLibrary(directory: libraryURL)
/// library.load()
/// library.addIPSW(at: ipswURL, name: "macOS 15.4")
/// let images = library.images
/// ```
public final class ImageLibrary: @unchecked Sendable {

    /// The directory where images and metadata are stored.
    public let directory: URL

    /// All known images.
    public private(set) var images: [VMImage] = []

    /// Path to the library index file.
    private var indexURL: URL {
        directory.appendingPathComponent("library.json")
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// Loads the image library from disk.
    public func load() {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.images.error("Failed to create image library directory: \(error.localizedDescription, privacy: .public)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: indexURL)
        } catch {
            Log.images.error("Failed to read image library index: \(error.localizedDescription, privacy: .public)")
            images = []
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            images = try decoder.decode([VMImage].self, from: data)
        } catch {
            Log.images.error("Failed to decode image library index: \(error.localizedDescription, privacy: .public)")
            images = []
        }
    }

    /// Adds a local IPSW file to the library.
    ///
    /// The file is copied (or moved) into the library directory.
    public func addIPSW(at url: URL, name: String) throws {
        let fm = FileManager.default
        let destURL = directory.appendingPathComponent(url.lastPathComponent)

        if url.path != destURL.path {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: url, to: destURL)
        }

        let attrs = try? fm.attributesOfItem(atPath: destURL.path)
        let size = attrs?[.size] as? UInt64

        let image = VMImage(
            name: name,
            source: .ipsw(path: destURL.path),
            sizeInBytes: size
        )
        images.append(image)
        try save()
    }

    /// Adds an OCI image reference to the library.
    public func addOCI(reference: String, name: String) throws {
        let image = VMImage(
            name: name,
            source: .oci(reference: reference)
        )
        images.append(image)
        try save()
    }

    /// Removes an image from the library.
    public func remove(id: UUID) throws {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let image = images[index]

        // Delete the file if it's a local IPSW.
        if case .ipsw(let path) = image.source {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                Log.images.error("Failed to delete IPSW file at '\(path, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }

        images.remove(at: index)
        try save()
    }

    private func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(images)
        try data.write(to: indexURL)
    }
}
