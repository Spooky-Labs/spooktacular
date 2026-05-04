import Foundation
import SpooktacularCore
import SpooktacularApplication
import os
@preconcurrency import Virtualization

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

    /// File name for the `VZVirtualMachine.saveMachineStateTo(url:)`
    /// output. When this file is present in a bundle, the next
    /// `start()` boots by ``VirtualMachine/restoreState(from:)``
    /// instead of a cold boot — the "close the laptop" workflow.
    ///
    /// The name + extension match Apple's sample code
    /// ("Running macOS in a Virtual Machine on Apple Silicon"):
    /// they use `SaveFile.vzvmsave`. Following the first-party
    /// naming so a developer inspecting a Spooktacular bundle
    /// recognises the file immediately.
    public static let savedStateFileName = "SaveFile.vzvmsave"

    /// File name for the EFI NVRAM variable store (Linux guests
    /// only; macOS guests use `auxiliary.bin` via
    /// `VZMacAuxiliaryStorage` instead). Holds the `VZEFIVariableStore`
    /// created at bundle-creation time; survives reboots so
    /// GRUB / systemd-boot remembers the next-boot entry.
    ///
    /// Apple's WWDC22 Linux sample uses `NVRAM` or `efi-nvram`
    /// interchangeably; we pick `efi-nvram.bin` to mirror the
    /// existing `hardware-model.bin` / `machine-identifier.bin`
    /// naming pattern in this bundle layout.
    public static let efiVariableStoreFileName = "efi-nvram.bin"

    /// File name for an installer ISO (Linux guests only).
    /// When present, ``applyStorage(from:to:)`` appends it as
    /// a read-only `VZUSBMassStorageDeviceConfiguration` so the
    /// firmware boots it ahead of the main disk. First-boot
    /// install flow: bundle is created with this file present,
    /// user runs the installer which writes the OS to
    /// `disk.img`, then deletes this file (or we delete it
    /// after the installer reports success in a future pass).
    public static let installerISOFileName = "installer.iso"

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

    // MARK: - Bundle URLs

    /// Absolute URL of the optional save-state file used by the
    /// suspend/resume workflow. See ``savedStateFileName`` for
    /// details.
    public var savedStateURL: URL {
        url.appendingPathComponent(Self.savedStateFileName)
    }

    /// `true` when a `SavedState.vzstate` file is present in the
    /// bundle — i.e., the VM was last shut down via `spook
    /// suspend` (or the GUI Suspend button) and the next
    /// `start()` should `restoreState(from:)` instead of cold-
    /// booting.
    ///
    /// The file is consumed (deleted) by a successful restore so
    /// a second start is always a cold boot.
    public var hasSavedState: Bool {
        FileManager.default.fileExists(atPath: savedStateURL.path)
    }

    /// Absolute URL of the EFI NVRAM variable store. Present
    /// as a file on disk only for Linux bundles — `create`
    /// provisions it at bundle-create time; macOS bundles
    /// leave this URL dangling (no file at the path).
    public var efiVariableStoreURL: URL {
        url.appendingPathComponent(Self.efiVariableStoreFileName)
    }

    /// `true` when the EFI NVRAM file exists on disk. Checked
    /// by ``VirtualMachineConfiguration/applyPlatform(from:to:)``
    /// for Linux guests — if present, the store is loaded via
    /// `VZEFIVariableStore(url:)`; if absent the boot loader's
    /// `variableStore` stays nil and the firmware runs in
    /// "no NVRAM" mode.
    public var hasEFIVariableStore: Bool {
        FileManager.default.fileExists(atPath: efiVariableStoreURL.path)
    }

    /// Absolute URL of the installer ISO. Linux-only; present
    /// during the first-boot install flow, removed after the
    /// installer writes the OS to the main disk.
    public var installerISOURL: URL {
        url.appendingPathComponent(Self.installerISOFileName)
    }

    /// `true` when an `installer.iso` file exists in the bundle.
    /// Drives ``VirtualMachineConfiguration/applyStorage(from:to:)``
    /// to attach the ISO as a read-only USB mass-storage
    /// device so the EFI firmware boots from it.
    public var hasInstallerISO: Bool {
        FileManager.default.fileExists(atPath: installerISOURL.path)
    }

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

        // Validate BEFORE creating directories or writing files:
        // an invalid spec must fail closed without littering the
        // filesystem with a half-constructed bundle.
        try spec.validate()

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

        // For Linux guests, provision an empty EFI NVRAM
        // variable store at bundle-create time. The firmware
        // writes boot-entry + variable data here across
        // reboots; Apple's `VZEFIBootLoader.variableStore`
        // requires an existing file. `allowOverwrite` lets
        // us safely re-create (e.g. on bundle reset); the
        // file doesn't exist at this point regardless.
        //
        // macOS guests don't use EFI — `VZMacAuxiliaryStorage`
        // (auxiliary.bin) is the equivalent but managed by
        // `VZMacOSInstaller` during install, not here.
        if spec.guestOS == .linux {
            _ = try VZEFIVariableStore(
                creatingVariableStoreAt: url.appendingPathComponent(efiVariableStoreFileName),
                options: [.allowOverwrite]
            )

            // Persist a `VZGenericMachineIdentifier` so the
            // generic platform's identity is stable across
            // reboots. Apple's GUI-Linux sample does this
            // too: without a persistent ID, VZ generates a
            // fresh one every boot and the EFI NVRAM boot
            // entries (which reference the machine) go
            // stale, breaking the post-install boot flow.
            // The file layout piggybacks on the macOS
            // `machine-identifier.bin` name — different VZ
            // type (`VZGenericMachineIdentifier` vs.
            // `VZMacMachineIdentifier`), same opaque-Data
            // serialization pattern, bundle is never both
            // at once.
            try VZGenericMachineIdentifier().dataRepresentation
                .write(to: url.appendingPathComponent(machineIdentifierFileName))
        }

        // Apply the recommended data-at-rest protection class —
        // CUFUA on laptops, none on desktops / EC2 Mac hosts. See
        // docs/DATA_AT_REST.md for the OWASP ASVS mapping and the
        // full rationale. A failure here is logged but not fatal:
        // the bundle is still usable, and `spook doctor --strict`
        // surfaces the unprotected state so the operator can
        // migrate it explicitly via `spook bundle protect <name>`.
        let (protection, policy) = BundleProtection.recommendedPolicy()
        do {
            try BundleProtection.apply(protection, to: url)
            // Propagate to the config.json + metadata.json we just
            // wrote. Data.write does NOT always mirror the parent
            // directory's protection class — FileVault's inherit
            // behavior varies across volumes and APFS snapshot
            // states. Propagating explicitly here + at every other
            // bundle-write site makes the inheritance contract
            // auditable via BundleProtection.verifyInheritance.
            try BundleProtection.propagate(to: url)
            Log.vm.info(
                "Bundle '\(url.lastPathComponent, privacy: .public)' protection=\(protection.displayName, privacy: .public) policy=\(String(describing: policy), privacy: .public)"
            )
        } catch {
            Log.vm.warning(
                "Failed to apply protection class to '\(url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public). Bundle still created; run `spook bundle protect` to retry."
            )
        }

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
        // Re-propagate the bundle's protection class so the freshly
        // (atomically-renamed) config.json carries the same class as
        // the bundle dir itself. See docs/DATA_AT_REST.md § "VM
        // lifetime involves many writes".
        try? BundleProtection.propagate(to: bundleURL)
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
        // Same reason as `writeSpec` — atomic rename creates a fresh
        // inode whose class we must re-apply.
        try? BundleProtection.propagate(to: url)
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
