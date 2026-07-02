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

    /// Directory name for the per-VM provisioning share.
    ///
    /// Exposed to the guest via `VZVirtioFileSystemDeviceConfiguration`
    /// under the dedicated ``provisionShareTag`` (not the generic
    /// macOS automount tag — user shared folders still own that
    /// slot). The Guest Tools LaunchDaemon mounts it at
    /// `/Library/Application Support/Spooktacular/provision/` and
    /// executes `first-boot.sh` if present.
    ///
    /// Flat-file layout (no subdirectories):
    ///
    /// ```
    /// <bundle>.vm/provision/
    ///     first-boot.sh         — host writes; daemon runs + deletes
    ///     first-boot.ran.sh     — archived copy (daemon writes after run)
    ///     first-boot.stdout.log — captured stdout
    ///     first-boot.stderr.log — captured stderr
    ///     first-boot.exit-code  — "0\n" etc.; presence means "ran"
    /// ```
    ///
    /// Per-VM scoped (each bundle has its own); Apple's VZ
    /// framework enforces access via the effective host user's
    /// UID, so cross-VM leakage is structurally impossible.
    public static let provisionDirectoryName = "provision"

    /// Filename of the pending first-boot script. Host writes;
    /// the Guest Tools LaunchDaemon reads, executes once, and
    /// removes so the next boot no-ops.
    public static let provisionScriptFileName = "first-boot.sh"

    /// Filename of the archived script body after a run —
    /// a plain copy the operator can inspect to see exactly
    /// what was executed.
    public static let provisionRanScriptFileName = "first-boot.ran.sh"

    /// Captured stdout from the most recent first-boot run.
    public static let provisionStdoutLogFileName = "first-boot.stdout.log"

    /// Captured stderr from the most recent first-boot run.
    public static let provisionStderrLogFileName = "first-boot.stderr.log"

    /// Exit-code file — the daemon writes `"<code>\n"` after
    /// the script returns. Its presence is the single
    /// authoritative signal that a run completed.
    public static let provisionExitCodeFileName = "first-boot.exit-code"

    /// `virtio-fs` tag we announce to the guest for the
    /// provisioning share. The Guest-Tools-installed
    /// LaunchDaemon picks this tag explicitly via
    /// `mount_virtiofs <tag> <mount-point>` — deliberately
    /// NOT using `macOSGuestAutomountTag` so user-provided
    /// shared folders can still claim that slot without
    /// colliding with provisioning.
    public static let provisionShareTag = "spook-provision"

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

    /// The file URL of the `.vm` bundle directory. Always of
    /// the form `~/.spooktacular/vms/<uuid>.vm` for bundles
    /// created under the UUID primary-key scheme; legacy
    /// `<name>.vm` directories are migrated to `<uuid>.vm` by
    /// ``load(from:)`` on first load.
    public let url: URL

    /// The hardware specification for this VM.
    public let spec: VirtualMachineSpecification

    /// The runtime metadata for this VM.
    public let metadata: VirtualMachineMetadata

    // MARK: - Identity convenience

    /// The VM's stable UUID — the primary key used by
    /// `AppState`, the CLI resolver, the HTTP API router, and
    /// every per-VM dictionary in memory. Pulled from
    /// ``metadata``.
    public var id: UUID { metadata.id }

    /// The user-facing label — mutable via
    /// ``Spooktacular/AppState/renameVM(id:to:)``. Pulled from
    /// ``metadata``. Two VMs can share the same displayName;
    /// identity is `id`, not this.
    public var displayName: String { metadata.displayName }

    // MARK: - Bundle URLs

    /// Absolute URL of the optional save-state file used by the
    /// suspend/resume workflow. See ``savedStateFileName`` for
    /// details.
    public var savedStateURL: URL {
        url.appendingPathComponent(Self.savedStateFileName)
    }

    /// Absolute URL of the per-VM provisioning share root
    /// (host-side view of what the guest mounts at
    /// `/Library/Application Support/Spooktacular/provision/`).
    public var provisionDirectoryURL: URL {
        url.appendingPathComponent(Self.provisionDirectoryName, isDirectory: true)
    }

    /// Absolute URL of the pending first-boot script. Host
    /// writes here via ``SpooktacularInfrastructureApple/DiskInjector/inject(script:into:)``;
    /// the guest daemon consumes and deletes it on next boot.
    public var provisionScriptURL: URL {
        provisionDirectoryURL.appendingPathComponent(Self.provisionScriptFileName)
    }

    /// Absolute URL of the archived copy of the last-run
    /// script — written by the daemon after a successful run
    /// so the operator can inspect the exact script body that
    /// executed.
    public var provisionRanScriptURL: URL {
        provisionDirectoryURL.appendingPathComponent(Self.provisionRanScriptFileName)
    }

    /// Absolute URL of the captured stdout from the most
    /// recent first-boot run.
    public var provisionStdoutURL: URL {
        provisionDirectoryURL.appendingPathComponent(Self.provisionStdoutLogFileName)
    }

    /// Absolute URL of the captured stderr from the most
    /// recent first-boot run.
    public var provisionStderrURL: URL {
        provisionDirectoryURL.appendingPathComponent(Self.provisionStderrLogFileName)
    }

    /// Absolute URL of the exit-code file. Existence alone
    /// indicates a completed run; contents parse to an
    /// integer exit status.
    public var provisionExitCodeURL: URL {
        provisionDirectoryURL.appendingPathComponent(Self.provisionExitCodeFileName)
    }

    /// Reads the current first-boot state off disk and returns
    /// a ``ProvisioningActivity`` snapshot the UI can bind to.
    ///
    /// Cheap enough to call on a UI-driven poll (a handful of
    /// `stat(2)` calls per invocation); not worth caching. If
    /// the provision directory doesn't exist yet — common for
    /// legacy bundles that predate this field — the call
    /// returns an empty snapshot.
    public func readProvisioningActivity() -> ProvisioningActivity {
        let fm = FileManager.default
        let scriptURL = provisionScriptURL
        let exitCodeURL = provisionExitCodeURL

        let scriptPending = fm.fileExists(atPath: scriptURL.path)
        let scriptPendingSince: Date? = scriptPending
            ? (try? scriptURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
            : nil

        var lastRun: ProvisioningActivity.Run?
        if let exitCodeString = try? String(
            contentsOf: exitCodeURL,
            encoding: .utf8
        ) {
            let trimmed = exitCodeString.trimmingCharacters(in: .whitespacesAndNewlines)
            let exitCode = Int(trimmed) ?? -1
            let completedAt = (try? exitCodeURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ))?.contentModificationDate
                ?? .distantPast
            lastRun = ProvisioningActivity.Run(
                completedAt: completedAt,
                exitCode: exitCode,
                stdoutBytes: Self.sizeOfFile(at: provisionStdoutURL, using: fm),
                stderrBytes: Self.sizeOfFile(at: provisionStderrURL, using: fm)
            )
        }

        return ProvisioningActivity(
            scriptPending: scriptPending,
            scriptPendingSince: scriptPendingSince,
            lastRun: lastRun
        )
    }

    private static func sizeOfFile(
        at url: URL,
        using fm: FileManager
    ) -> Int {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return 0 }
        return size
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
    ///     created. Must not already exist. Typically produced
    ///     via ``SpooktacularPaths/bundleURL(for:)-8y2wf`` so the
    ///     directory name matches the metadata UUID.
    ///   - spec: The hardware specification for the VM.
    ///   - displayName: The user-facing label stored in
    ///     `metadata.json`. See
    ///     ``SpooktacularCore/VirtualMachineMetadata/displayName``.
    /// - Returns: The newly created bundle.
    /// - Throws: ``VirtualMachineBundleError/alreadyExists(url:)`` if a file
    ///   or directory already exists at `url`.
    public static func create(
        at url: URL,
        spec: VirtualMachineSpecification,
        displayName: String
    ) throws -> VirtualMachineBundle {
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

        // Align the metadata UUID with the URL's basename —
        // the filesystem encodes identity too, and they must
        // agree. If the basename doesn't parse as a UUID
        // (e.g. a test path like `/tmp/foo.vm`), fall back to
        // a freshly-minted one; callers using UUID-keyed paths
        // (which is every runtime site) get deterministic
        // round-tripping.
        let basename = url.deletingPathExtension().lastPathComponent
        let id = UUID(uuidString: basename) ?? UUID()
        let metadata = VirtualMachineMetadata(id: id, displayName: displayName)

        let configData = try Self.encoder.encode(spec)
        try configData.write(to: url.appendingPathComponent(configFileName), options: .atomic)

        let metadataData = try Self.encoder.encode(metadata)
        try metadataData.write(to: url.appendingPathComponent(metadataFileName), options: .atomic)

        // Pre-create the per-VM provisioning share. The guest
        // mounts this via `VZVirtioFileSystemDevice` under
        // ``provisionShareTag`` and the Guest Tools LaunchDaemon
        // executes `first-boot.sh` at boot if the host has
        // written one.
        //
        // Created unconditionally (macOS and Linux guests
        // both): Linux doesn't use this path yet, but the
        // empty directory costs nothing and keeps the bundle
        // layout consistent.
        try fileManager.createDirectory(
            at: url.appendingPathComponent(provisionDirectoryName),
            withIntermediateDirectories: true
        )

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

    /// Loads an existing VM bundle from disk, migrating legacy
    /// name-keyed bundles to the UUID-keyed layout in-place.
    ///
    /// Two bundle-directory shapes coexist during the migration
    /// window:
    ///
    /// 1. **UUID-keyed** — `<uuid>.vm/` with `metadata.displayName`
    ///    already populated. Loaded verbatim.
    /// 2. **Legacy name-keyed** — `<name>.vm/` whose metadata
    ///    lacks a display name (decoded as `""`). This load
    ///    back-fills `displayName` from the directory basename,
    ///    re-writes `metadata.json`, and renames the directory
    ///    to `<id>.vm/`. The returned bundle carries the
    ///    post-migration URL so callers never touch the old
    ///    path again.
    ///
    /// Migration is idempotent: a second load on an already-
    /// migrated directory is a no-op.
    ///
    /// - Parameter url: The file URL of an existing `.vm` bundle
    ///   directory. May be either shape.
    /// - Returns: The loaded bundle, pointing at the UUID-keyed
    ///   path on disk.
    /// - Throws: ``VirtualMachineBundleError/notFound(url:)`` if
    ///   the directory does not exist.
    ///   ``VirtualMachineBundleError/invalidConfiguration(url:)``
    ///   or ``VirtualMachineBundleError/invalidMetadata(url:)``
    ///   if the JSON files are missing or malformed.
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
        var metadata = try decodeFile(
            VirtualMachineMetadata.self,
            at: url.appendingPathComponent(metadataFileName),
            orThrow: .invalidMetadata(url: url)
        )

        let basename = url.deletingPathExtension().lastPathComponent
        let directoryIsUUID = UUID(uuidString: basename) != nil
        let needsDisplayNameBackfill = metadata.displayName.isEmpty
        let needsRename = !directoryIsUUID

        if needsDisplayNameBackfill {
            // Legacy bundles carried the display name in the
            // directory basename only. Promote it into
            // `metadata.json` so subsequent loads don't need to
            // look at the path.
            metadata.displayName = basename
            try writeMetadata(metadata, to: url)
            Log.vm.info(
                "Backfilled displayName='\(basename, privacy: .public)' into metadata of legacy bundle (id=\(metadata.id.uuidString, privacy: .public))"
            )
        }

        let finalURL: URL
        if needsRename {
            // Move the directory to its UUID-keyed home. Same
            // parent dir, so this is an atomic `rename(2)` on
            // APFS — no data copy.
            let newURL = url
                .deletingLastPathComponent()
                .appendingPathComponent("\(metadata.id.uuidString).vm")
            // Target conflict is only possible if a VM with the
            // same UUID was already migrated. Shouldn't happen
            // (UUIDs are unique per bundle), but guard anyway.
            if FileManager.default.fileExists(atPath: newURL.path) {
                Log.vm.error(
                    "Cannot migrate \(basename, privacy: .public) → \(newURL.lastPathComponent, privacy: .public): destination already exists. Leaving bundle at legacy path."
                )
                finalURL = url
            } else {
                try FileManager.default.moveItem(at: url, to: newURL)
                Log.vm.info(
                    "Migrated legacy bundle \(basename, privacy: .public).vm → \(newURL.lastPathComponent, privacy: .public)"
                )
                finalURL = newURL
            }
        } else {
            finalURL = url
        }

        Log.vm.info("Loaded bundle '\(finalURL.lastPathComponent, privacy: .public)' — \(spec.cpuCount) CPU, \(spec.memorySizeInBytes / (1024*1024*1024)) GB RAM")
        return VirtualMachineBundle(url: finalURL, spec: spec, metadata: metadata)
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
