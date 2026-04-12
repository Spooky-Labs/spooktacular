import Foundation
import os

/// A virtual machine bundle stored on disk.
///
/// A `VMBundle` represents the on-disk directory structure for a
/// single macOS virtual machine. Each bundle is a `.vm` directory
/// containing the configuration, disk image, and platform-specific
/// artifacts required to boot and run the VM.
///
/// ## Bundle Directory Layout
///
/// ```
/// my-vm.vm/
/// ├── config.json              VM specification (CPU, memory, etc.)
/// ├── disk.img                 APFS sparse disk image
/// ├── auxiliary.bin            VZMacAuxiliaryStorage data
/// ├── hardware-model.bin       VZMacHardwareModel data
/// ├── machine-identifier.bin   VZMacMachineIdentifier data
/// └── metadata.json            Runtime metadata (UUID, dates, state)
/// ```
///
/// ## Creating a New Bundle
///
/// ```swift
/// let url = URL(fileURLWithPath: "~/.spooktacular/vms/my-vm.vm")
/// let spec = VMSpec(cpuCount: 8, memorySizeInBytes: 16_000_000_000)
/// let bundle = try VMBundle.create(at: url, spec: spec)
/// ```
///
/// ## Loading an Existing Bundle
///
/// ```swift
/// let bundle = try VMBundle.load(from: url)
/// print(bundle.spec.cpuCount)     // 8
/// print(bundle.metadata.id)       // unique UUID
/// ```
public struct VMBundle: Sendable {

    // MARK: - Constants

    /// File name for the VM hardware specification.
    public static let configFileName = "config.json"

    /// File name for the VM runtime metadata.
    public static let metadataFileName = "metadata.json"

    /// A JSON encoder configured for bundle files.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// A JSON decoder configured for bundle files.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Properties

    /// The file URL of the `.vm` bundle directory.
    public let url: URL

    /// The hardware specification for this VM.
    public let spec: VMSpec

    /// The runtime metadata for this VM.
    public let metadata: VMMetadata

    // MARK: - Creating Bundles

    /// Creates a new VM bundle directory at the specified location.
    ///
    /// This method creates the bundle directory and writes the
    /// initial `config.json` and `metadata.json` files. The caller
    /// is responsible for creating the disk image and platform
    /// artifacts separately (for example, via `VZMacOSInstaller`).
    ///
    /// - Parameters:
    ///   - url: The file URL where the `.vm` directory will be
    ///     created. Must not already exist.
    ///   - spec: The hardware specification for the VM.
    /// - Returns: The newly created bundle.
    /// - Throws: ``VMBundleError/alreadyExists(url:)`` if a file
    ///   or directory already exists at `url`.
    public static func create(at url: URL, spec: VMSpec) throws -> VMBundle {
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: url.path) else {
            Log.vm.error("Bundle already exists at \(url.lastPathComponent, privacy: .public)")
            throw VMBundleError.alreadyExists(url: url)
        }

        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        let metadata = VMMetadata()

        let configData = try Self.encoder.encode(spec)
        try configData.write(to: url.appendingPathComponent(configFileName))

        let metadataData = try Self.encoder.encode(metadata)
        try metadataData.write(to: url.appendingPathComponent(metadataFileName))

        Log.vm.info("Created bundle '\(url.lastPathComponent, privacy: .public)' — \(spec.cpuCount) CPU, \(spec.memorySizeInBytes / (1024*1024*1024)) GB RAM")
        return VMBundle(url: url, spec: spec, metadata: metadata)
    }

    // MARK: - Updating Bundles

    /// Writes updated metadata to an existing bundle directory.
    ///
    /// Replaces the `metadata.json` file in the bundle at the
    /// given URL with the provided metadata.
    ///
    /// - Parameters:
    ///   - metadata: The updated metadata to write.
    ///   - url: The file URL of the `.vm` bundle directory.
    public static func writeMetadata(_ metadata: VMMetadata, to url: URL) throws {
        let data = try Self.encoder.encode(metadata)
        try data.write(to: url.appendingPathComponent(metadataFileName))
    }

    // MARK: - Loading Bundles

    /// Loads an existing VM bundle from disk.
    ///
    /// Reads and parses the `config.json` and `metadata.json`
    /// files from the bundle directory.
    ///
    /// - Parameter url: The file URL of an existing `.vm` bundle
    ///   directory.
    /// - Returns: The loaded bundle.
    /// - Throws: ``VMBundleError/notFound(url:)`` if the directory
    ///   does not exist. ``VMBundleError/invalidConfiguration(url:)``
    ///   or ``VMBundleError/invalidMetadata(url:)`` if the JSON
    ///   files are missing or malformed.
    public static func load(from url: URL) throws -> VMBundle {
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: url.path) else {
            throw VMBundleError.notFound(url: url)
        }

        let configURL = url.appendingPathComponent(configFileName)
        let spec: VMSpec
        do {
            let data = try Data(contentsOf: configURL)
            spec = try Self.decoder.decode(VMSpec.self, from: data)
        } catch {
            throw VMBundleError.invalidConfiguration(url: url)
        }

        let metadataURL = url.appendingPathComponent(metadataFileName)
        let metadata: VMMetadata
        do {
            let data = try Data(contentsOf: metadataURL)
            metadata = try Self.decoder.decode(VMMetadata.self, from: data)
        } catch {
            throw VMBundleError.invalidMetadata(url: url)
        }

        return VMBundle(url: url, spec: spec, metadata: metadata)
    }
}
