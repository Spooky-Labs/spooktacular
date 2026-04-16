import Foundation
import SpookCore
import SpookApplication
import os

/// A virtual machine bundle stored on disk.
///
/// A `VirtualMachineBundle` represents the on-disk directory structure for a
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
/// let url = URL(filePath: "~/.spooktacular/vms/my-vm.vm")
/// let spec = VirtualMachineSpecification(cpuCount: 8, memorySizeInBytes: 16_000_000_000)
/// let bundle = try VirtualMachineBundle.create(at: url, spec: spec)
/// ```
///
/// ## Loading an Existing Bundle
///
/// ```swift
/// let bundle = try VirtualMachineBundle.load(from: url)
/// print(bundle.spec.cpuCount)     // 8
/// print(bundle.metadata.id)       // unique UUID
/// ```
public struct VirtualMachineBundle: Sendable {

    // MARK: - Constants

    /// File name for the VM hardware specification.
    public static let configFileName = "config.json"

    /// File name for the VM runtime metadata.
    public static let metadataFileName = "metadata.json"

    /// File name for the APFS sparse disk image.
    public static let diskImageFileName = "disk.img"

    /// File name for the `VZMacAuxiliaryStorage` data.
    public static let auxiliaryStorageFileName = "auxiliary.bin"

    /// File name for the `VZMacHardwareModel` data.
    public static let hardwareModelFileName = "hardware-model.bin"

    /// File name for the `VZMacMachineIdentifier` data.
    public static let machineIdentifierFileName = "machine-identifier.bin"

    /// A JSON encoder configured for bundle files.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// A JSON decoder configured for bundle files.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Properties

    /// The file URL of the `.vm` bundle directory.
    public let url: URL

    /// The hardware specification for this VM.
    public let spec: VirtualMachineSpecification

    /// The runtime metadata for this VM.
    public let metadata: VirtualMachineMetadata

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
    /// - Throws: ``VirtualMachineBundleError/alreadyExists(url:)`` if a file
    ///   or directory already exists at `url`.
    public static func create(at url: URL, spec: VirtualMachineSpecification) throws -> VirtualMachineBundle {
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: url.path) else {
            Log.vm.error("Bundle already exists at \(url.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.alreadyExists(url: url)
        }

        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )

        let metadata = VirtualMachineMetadata()

        let configData = try Self.encoder.encode(spec)
        try configData.write(to: url.appendingPathComponent(configFileName), options: .atomic)

        let metadataData = try Self.encoder.encode(metadata)
        try metadataData.write(to: url.appendingPathComponent(metadataFileName), options: .atomic)

        Log.vm.info("Created bundle '\(url.lastPathComponent, privacy: .public)' — \(spec.cpuCount) CPU, \(spec.memorySizeInBytes / (1024*1024*1024)) GB RAM")
        return VirtualMachineBundle(url: url, spec: spec, metadata: metadata)
    }

    // MARK: - Updating Bundles

    /// Writes updated specification to an existing bundle directory.
    ///
    /// Replaces the `config.json` file in the bundle at the
    /// given URL with the provided specification.
    ///
    /// - Parameters:
    ///   - spec: The updated specification to write.
    ///   - bundleURL: The file URL of the `.vm` bundle directory.
    public static func writeSpec(_ spec: VirtualMachineSpecification, to bundleURL: URL) throws {
        let data = try encoder.encode(spec)
        try data.write(to: bundleURL.appendingPathComponent(configFileName), options: .atomic)
    }

    /// Writes updated metadata to an existing bundle directory.
    ///
    /// Replaces the `metadata.json` file in the bundle at the
    /// given URL with the provided metadata.
    ///
    /// - Parameters:
    ///   - metadata: The updated metadata to write.
    ///   - url: The file URL of the `.vm` bundle directory.
    public static func writeMetadata(_ metadata: VirtualMachineMetadata, to url: URL) throws {
        Log.vm.debug("Writing metadata to \(url.lastPathComponent, privacy: .public)")
        let data = try Self.encoder.encode(metadata)
        try data.write(to: url.appendingPathComponent(metadataFileName), options: .atomic)
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
    /// - Throws: ``VirtualMachineBundleError/notFound(url:)`` if the directory
    ///   does not exist. ``VirtualMachineBundleError/invalidConfiguration(url:)``
    ///   or ``VirtualMachineBundleError/invalidMetadata(url:)`` if the JSON
    ///   files are missing or malformed.
    public static func load(from url: URL) throws -> VirtualMachineBundle {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.vm.error("Bundle not found at \(url.lastPathComponent, privacy: .public)")
            throw VirtualMachineBundleError.notFound(url: url)
        }

        Log.vm.debug("Loading bundle from \(url.lastPathComponent, privacy: .public)")

        let spec = try decodeFile(
            VirtualMachineSpecification.self,
            at: url.appendingPathComponent(configFileName),
            orThrow: .invalidConfiguration(url: url)
        )
        let metadata = try decodeFile(
            VirtualMachineMetadata.self,
            at: url.appendingPathComponent(metadataFileName),
            orThrow: .invalidMetadata(url: url)
        )

        Log.vm.info("Loaded bundle '\(url.lastPathComponent, privacy: .public)' — \(spec.cpuCount) CPU, \(spec.memorySizeInBytes / (1024*1024*1024)) GB RAM")
        return VirtualMachineBundle(url: url, spec: spec, metadata: metadata)
    }

    // MARK: - Private

    /// Decodes a JSON file, rethrowing as the specified bundle error on failure.
    private static func decodeFile<T: Decodable>(
        _ type: T.Type,
        at url: URL,
        orThrow bundleError: VirtualMachineBundleError
    ) throws -> T {
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(type, from: data)
        } catch {
            Log.vm.error("Failed to decode \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw bundleError
        }
    }
}
