import Foundation
import Virtualization
import SpooktacularApplication
import os

/// Progress reported while a base image is built.
public enum BaseBuildProgress: Sendable, Equatable {

    /// macOS is installing into the base image.
    case installing(fraction: Double)

    /// The provisioner LaunchDaemon is being injected (requires root).
    case injectingProvisioner

    /// The base is being sealed read-only.
    case sealing
}

/// Builds the installed-once macOS base image that every VM overlays.
///
/// Exactly one step of a build is privileged — injecting the
/// `root:wheel` LaunchDaemon into the guest image — and that step is
/// delegated to a ``ProvisionerInjecting``. A root process injects
/// directly; the GUI routes it through its approved SMAppService helper.
/// Everything else here (creating the ASIF image, running the
/// installer, sealing the result) runs as the ordinary user, and once
/// the base exists creating VMs from it is entirely unprivileged.
///
/// The base is deliberately **never booted**. That keeps its
/// `layerUUID` stable for every overlay stacked on it, and it means
/// each VM's first boot is genuinely the guest's "first boot after
/// restore" — the moment `VZMacGuestProvisioningOptions` creates that
/// VM's own account.
@available(macOS 27, *)
public final class BaseImageBuilder {

    /// Identifies the provisioner assets baked into a base.
    ///
    /// Bump this when the injected daemon or runner script changes, so
    /// stale bases are rebuilt rather than silently reused by VMs that
    /// would then be missing the new behaviour.
    public static let provisionerVersion = "1"

    private let store: BaseImageStore
    private static let log = Logger(subsystem: "com.spooktacular", category: "base-image")

    /// Creates a builder writing into a store.
    ///
    /// - Parameter store: The base-image cache.
    public init(store: BaseImageStore) {
        self.store = store
    }

    /// Returns the cached descriptor for a build when it is complete
    /// and was produced by the current provisioner version.
    ///
    /// - Parameter build: The macOS build string.
    /// - Returns: The descriptor, or `nil` when a build is required.
    /// - Throws: ``BaseImageStoreError`` when a descriptor exists but
    ///   cannot be decoded.
    public func cachedDescriptor(forBuild build: String) throws -> BaseImageDescriptor? {
        guard store.hasBase(forBuild: build),
              let descriptor = try store.descriptor(forBuild: build),
              descriptor.provisionerVersion == Self.provisionerVersion else {
            return nil
        }
        return descriptor
    }

    /// Clears the write bits so the base cannot be modified while
    /// overlays depend on it.
    ///
    /// DiskImageKit only writes to the topmost layer of a stack, so the
    /// base is already safe in normal use; sealing defends against
    /// anything outside the framework touching it.
    ///
    /// - Parameter url: The base image file.
    /// - Throws: ``BaseImageBuildError/sealFailed(_:)`` on failure.
    public func seal(at url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o444],
                ofItemAtPath: url.path
            )
        } catch {
            throw BaseImageBuildError.sealFailed(url)
        }
    }

    /// Returns the existing base for the restore image's build, or
    /// builds one.
    ///
    /// - Parameters:
    ///   - restoreImage: The macOS restore image, used for its build
    ///     version and hardware model.
    ///   - installMediaURL: The **local** IPSW file to install from.
    ///     Passed separately because a restore image obtained from
    ///     `fetchLatestSupported()` carries Apple's remote URL, and
    ///     installing from that would re-download the ~19 GB the
    ///     caller has already cached.
    ///   - sizeInBytes: Logical size of the base disk.
    ///   - injector: Performs the one privileged step. Its `preflight()`
    ///     runs before the install, so a permissions problem surfaces in
    ///     milliseconds instead of after 20 minutes of work.
    ///   - progress: Receives build progress. Not called on a cache hit.
    /// - Returns: The descriptor of the ready base.
    /// - Throws: ``BaseImageBuildError`` or a framework error.
    public func ensureBase(
        restoreImage: VZMacOSRestoreImage,
        installMediaURL: URL,
        sizeInBytes: UInt64,
        injector: ProvisionerInjecting = DirectProvisionerInjector(),
        progress: @escaping @Sendable (BaseBuildProgress) -> Void
    ) async throws -> BaseImageDescriptor {
        let build = restoreImage.buildVersion
        if let cached = try cachedDescriptor(forBuild: build) { return cached }

        // Fail fast before the install: the injector decides whether it
        // can do privileged work (root in-process, or an approved
        // helper) and says so now rather than 20 minutes from now.
        try await injector.preflight()
        guard let supported = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw BaseImageBuildError.unsupportedRestoreImage(build: build)
        }

        return try await store.withBuildLock(forBuild: build) {
            // Another process may have finished while we waited.
            if let cached = try cachedDescriptor(forBuild: build) { return cached }

            let directory = store.directory(forBuild: build)
            let staging = directory.appendingPathComponent("staging", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            let stagedImage = staging.appendingPathComponent("base.asif")
            let stagedAux = staging.appendingPathComponent("auxiliary.bin")
            let stagedModel = staging.appendingPathComponent("hardware-model.bin")
            let stagedIdentifier = staging.appendingPathComponent("machine-identifier.bin")

            // The UUID this returns describes the *empty* image. Apple's
            // installer rewrites the layer, so it is not the identity a VM
            // will later see; the real one is read back after the install.
            _ = try DiskStack.createBase(at: stagedImage, sizeInBytes: sizeInBytes)

            let hardwareModel = supported.hardwareModel
            try hardwareModel.dataRepresentation.write(to: stagedModel, options: .atomic)
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: stagedAux,
                hardwareModel: hardwareModel,
                options: []
            )

            // The installer personalizes the auxiliary storage against
            // the machine identifier it runs with, and Apple requires
            // that "when you save a VM to disk and load it again, you
            // must restore the hardwareModel, machineIdentifier and
            // auxiliaryStorage properties to their original values".
            // An overlay VM *is* this disk loaded again, so the
            // identifier used here must be persisted and reused by
            // every VM built on this base — minting a fresh one per VM
            // would pair a personalized aux with a stranger's identity.
            let machineIdentifier = VZMacMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(
                to: stagedIdentifier,
                options: .atomic
            )

            try await Self.runInstaller(
                restoreURL: installMediaURL,
                hardwareModelData: hardwareModel.dataRepresentation,
                machineIdentifierData: machineIdentifier.dataRepresentation,
                cpuCount: max(supported.minimumSupportedCPUCount, 4),
                memorySize: max(supported.minimumSupportedMemorySize, 8 * 1024 * 1024 * 1024),
                label: "spook-base-\(build)",
                image: stagedImage,
                auxiliary: stagedAux,
                progress: progress
            )

            progress(.injectingProvisioner)
            try await injector.injectProvisioner(intoDiskImageAt: stagedImage)

            // Read the layer identity from the finished image, not the empty
            // one created above. VZMacOSInstaller regenerates it while writing
            // the guest, so recording the pre-install value made every VM fail
            // its lineage check on first start with "The base image changed
            // since this VM was created" — the guard working correctly against
            // a value that was wrong the moment it was written.
            let layerUUID = try DiskStack.baseLayerUUID(at: stagedImage)

            progress(.sealing)
            try seal(at: stagedImage)
            try Self.promote(from: staging, to: directory)

            let descriptor = BaseImageDescriptor(
                buildVersion: build,
                layerUUID: layerUUID,
                sizeInBytes: sizeInBytes,
                createdAt: Date(),
                provisionerVersion: Self.provisionerVersion
            )
            try store.write(descriptor)
            Self.log.notice("Built base image for macOS build \(build, privacy: .public)")
            return descriptor
        }
    }

    /// Moves finished staging files into their final names.
    ///
    /// Building into `staging/` and renaming at the end means an
    /// interrupted build leaves no half-written base that a later run
    /// might mistake for a complete one.
    private static func promote(from staging: URL, to directory: URL) throws {
        let fileManager = FileManager.default
        for name in ["base.asif", "auxiliary.bin", "hardware-model.bin", "machine-identifier.bin"] {
            let source = staging.appendingPathComponent(name)
            let destination = directory.appendingPathComponent(name)
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: source, to: destination)
        }
        try? fileManager.removeItem(at: staging)
    }

    /// Runs `VZMacOSInstaller` against a throwaway configuration whose
    /// only storage is the staged base image.
    ///
    /// `VZVirtualMachine` and `VZMacOSInstaller` are main-actor types
    /// and their configuration is not `Sendable`, so the whole
    /// configuration is assembled here on the main actor and only
    /// `Sendable` values cross the boundary — the hardware model
    /// travels as its data representation and is rebuilt inside.
    ///
    /// The install itself is awaited through a continuation, so a
    /// twenty-minute install suspends rather than blocking a thread.
    ///
    /// - Parameters:
    ///   - restoreURL: The IPSW to restore from.
    ///   - hardwareModelData: Serialized `VZMacHardwareModel`.
    ///   - machineIdentifierData: Serialized `VZMacMachineIdentifier`. The
    ///     installer personalizes the auxiliary storage against this
    ///     identity, so it is persisted with the base and reused by
    ///     every VM overlaid on it.
    ///   - cpuCount: CPU count for the installer VM.
    ///   - memorySize: Memory size for the installer VM.
    ///   - label: Configuration label, for host-side diagnostics.
    ///   - image: The staged base image to install into.
    ///   - auxiliary: The staged auxiliary storage.
    ///   - progress: Receives install progress.
    /// - Throws: ``BaseImageBuildError`` or a framework error.
    @MainActor
    private static func runInstaller(
        restoreURL: URL,
        hardwareModelData: Data,
        machineIdentifierData: Data,
        cpuCount: Int,
        memorySize: UInt64,
        label: String,
        image: URL,
        auxiliary: URL,
        progress: @escaping @Sendable (BaseBuildProgress) -> Void
    ) async throws {
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw BaseImageBuildError.unsupportedRestoreImage(build: label)
        }
        guard let machineIdentifier = VZMacMachineIdentifier(
            dataRepresentation: machineIdentifierData
        ) else {
            throw BaseImageBuildError.unsupportedRestoreImage(build: label)
        }

        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = cpuCount
        configuration.memorySize = memorySize
        configuration.label = label

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: auxiliary)
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: try DiskStack.writableAttachment(at: image)),
        ]
        try configuration.validate()

        let machine = VZVirtualMachine(configuration: configuration)
        let installer = VZMacOSInstaller(
            virtualMachine: machine,
            restoringFromImageAt: restoreURL
        )
        let observation = installer.progress.observe(
            \.fractionCompleted,
            options: [.initial, .new]
        ) { value, _ in
            progress(.installing(fraction: value.fractionCompleted))
        }
        defer { observation.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            installer.install { result in
                continuation.resume(with: result)
            }
        }
    }
}

/// Diagnostics for base-image builds.
public enum BaseImageBuildError: Error, Sendable, Equatable, LocalizedError {

    /// The provisioner plist/runner could not be located.
    case provisionerAssetsMissing

    /// The build needs root and the process does not have it.
    case requiresRoot

    /// The restore image reports no supported configuration for this host.
    case unsupportedRestoreImage(build: String)

    /// The base image could not be made read-only.
    case sealFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .provisionerAssetsMissing:
            "Provisioner assets were not found."
        case .requiresRoot:
            "Building the macOS base image requires root."
        case .unsupportedRestoreImage(let build):
            "macOS build \(build) is not supported on this host."
        case .sealFailed(let url):
            "Could not seal the base image at '\(url.path)' read-only."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .provisionerAssetsMissing:
            "Run ./build-app.sh so Resources/SpookProvisioner/ is staged into the app bundle."
        case .requiresRoot:
            "On an EC2 Mac, run under the root service. Locally, run 'sudo spook create …' once, or approve Spooktacular's privileged helper in System Settings. Only the first create needs this — every VM afterwards is unprivileged."
        case .unsupportedRestoreImage:
            "Use a restore image that matches this Mac's hardware."
        case .sealFailed:
            "Check permissions on ~/.spooktacular/cache/base/."
        }
    }
}
