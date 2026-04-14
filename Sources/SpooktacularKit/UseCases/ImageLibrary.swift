import Foundation

/// A cached VM image available for creating new virtual machines.
///
/// Images can be either local IPSW files or OCI references.
/// The library tracks which images are cached on disk and
/// available for instant VM creation.
public struct VirtualMachineImage: Sendable, Codable, Equatable, Identifiable {

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
/// - Important: This class is not thread-safe. Access it only
///   from `@MainActor` (as `AppState` does) or a single serial
///   context.
public final class ImageLibrary: @unchecked Sendable {

    /// The directory where images and metadata are stored.
    public let directory: URL

    /// Logger for diagnostic messages.
    private let log: any LogProvider

    /// All known images.
    public private(set) var images: [VirtualMachineImage] = []

    /// Path to the library index file.
    private var indexURL: URL {
        directory.appendingPathComponent("library.json")
    }

    /// Creates an image library backed by the given directory.
    ///
    /// - Parameters:
    ///   - directory: The directory where images and metadata are stored.
    ///   - log: Logger for diagnostic messages. Defaults to a
    ///     silent provider.
    public init(directory: URL, log: any LogProvider = SilentLogProvider()) {
        self.directory = directory
        self.log = log
    }

    /// Loads the image library from disk.
    public func load() {
        log.info("Loading image library from \(self.directory.path)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("Failed to create image library directory: \(error.localizedDescription)")
        }

        do {
            let data = try Data(contentsOf: indexURL)
            images = try VirtualMachineBundle.decoder.decode([VirtualMachineImage].self, from: data)
            log.info("Loaded \(self.images.count) image(s) from library")
        } catch {
            log.debug("No existing image library index: \(error.localizedDescription)")
            images = []
        }
    }

    /// Adds a local IPSW file to the library.
    ///
    /// The file is copied (or moved) into the library directory.
    public func addIPSW(at url: URL, name: String) throws {
        log.info("Adding IPSW '\(name)' from \(url.lastPathComponent)")
        let destinationURL = directory.appendingPathComponent(url.lastPathComponent)

        if url.path != destinationURL.path {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.copyItem(at: url, to: destinationURL)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destinationURL.path))?[.size] as? UInt64
        images.append(VirtualMachineImage(
            name: name,
            source: .ipsw(path: destinationURL.path),
            sizeInBytes: size
        ))
        try save()
    }

    /// Adds an OCI image reference to the library.
    public func addOCI(reference: String, name: String) throws {
        log.info("Adding OCI image '\(name)' (\(reference))")
        images.append(VirtualMachineImage(
            name: name,
            source: .oci(reference: reference)
        ))
        try save()
    }

    /// Removes an image from the library.
    public func remove(id: UUID) throws {
        guard let index = images.firstIndex(where: { $0.id == id }) else {
            log.debug("Image \(id) not found in library — nothing to remove")
            return
        }
        let image = images[index]
        log.info("Removing image '\(image.name)' from library")

        if case .ipsw(let path) = image.source {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                log.error("Failed to delete IPSW at '\(path)': \(error.localizedDescription)")
            }
        }

        images.remove(at: index)
        try save()
    }

    private func save() throws {
        let data = try VirtualMachineBundle.encoder.encode(images)
        try data.write(to: indexURL)
    }
}
