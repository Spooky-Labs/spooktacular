import Foundation
import os
import Virtualization

/// Manages macOS restore images (IPSWs) for virtual machine installation.
///
/// `RestoreImageManager` handles downloading, caching, and installing
/// macOS from Apple's IPSW restore images. Downloaded images are
/// cached by SHA256 hash to avoid redundant downloads.
///
/// ## Creating a VM from an IPSW
///
/// ```swift
/// let manager = RestoreImageManager(cacheDirectory: cacheURL)
///
/// // 1. Download the latest macOS restore image.
/// let ipsw = try await manager.fetchLatestSupported()
///
/// // 2. Create a bundle with platform artifacts from the image.
/// let bundle = try await manager.createBundle(
///     named: "my-vm",
///     in: vmsDirectory,
///     from: ipsw,
///     spec: VirtualMachineSpecification(cpuCount: 8)
/// )
///
/// // 3. Install macOS into the bundle.
/// try await manager.install(bundle: bundle, from: ipsw) { progress in
///     print("Installing: \(Int(progress * 100))%")
/// }
/// ```
///
/// ## Cache Layout
///
/// ```
/// ~/.spooktacular/cache/ipsw/
/// └── <sha256>.ipsw
/// ```
public final class RestoreImageManager: Sendable {

    /// The directory where IPSW files are cached.
    public let cacheDirectory: URL

    /// Creates a restore image manager.
    ///
    /// - Parameter cacheDirectory: The directory for cached
    ///   IPSW files. Created automatically if it does not exist.
    public init(cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
    }

    // MARK: - Fetching Restore Images

    /// Fetches metadata for the latest supported macOS restore image
    /// and verifies it is compatible with the host.
    ///
    /// Queries Apple's servers for the most recent macOS version
    /// that can run on this host's hardware, then checks that
    /// the host OS is new enough to install it. This check
    /// runs **before** any download begins.
    ///
    /// All interfaces (CLI, GUI, API, K8s operator) call this
    /// method, ensuring consistent compatibility behavior.
    ///
    /// - Returns: The restore image metadata, including the
    ///   download URL and hardware requirements.
    /// - Throws: ``RestoreImageError/incompatibleHost(message:)``
    ///   if the host macOS is too old.
    public func fetchLatestSupported() async throws -> VZMacOSRestoreImage {
        Log.ipsw.info("Fetching latest supported restore image from Apple")
        let image = try await VZMacOSRestoreImage.latestSupported

        let version = image.operatingSystemVersion
        Log.ipsw.info("Latest IPSW: macOS \(version.majorVersion, privacy: .public).\(version.minorVersion, privacy: .public).\(version.patchVersion, privacy: .public) (build \(image.buildVersion, privacy: .public))")

        let result = Compatibility.check(
            imageVersion: image.operatingSystemVersion
        )
        if let message = result.errorMessage {
            Log.compatibility.error("Version mismatch: \(message, privacy: .public)")
            throw RestoreImageError.incompatibleHost(message: message)
        }

        Log.compatibility.info("Host version compatible with IPSW")
        return image
    }

    /// Downloads the IPSW file for a restore image.
    ///
    /// If the file is already cached (by URL filename), the cached
    /// path is returned without re-downloading.
    ///
    /// - Parameters:
    ///   - restoreImage: The restore image to download.
    ///   - progress: A closure called periodically with the
    ///     fraction completed (0.0–1.0).
    /// - Returns: The local file URL of the downloaded IPSW.
    public func downloadIPSW(
        from restoreImage: VZMacOSRestoreImage,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        let fileName = restoreImage.url.lastPathComponent
        let localURL = cacheDirectory.appendingPathComponent(fileName)

        // Return cached file if it exists.
        if fileManager.fileExists(atPath: localURL.path) {
            Log.ipsw.info("Using cached IPSW at \(localURL.lastPathComponent, privacy: .public)")
            return localURL
        }

        // Download the IPSW.
        Log.ipsw.info("Downloading IPSW from \(restoreImage.url.lastPathComponent, privacy: .public)")
        let (tempURL, _) = try await URLSession.shared.download(
            from: restoreImage.url,
            delegate: DownloadProgressDelegate(handler: progress)
        )

        try fileManager.moveItem(at: tempURL, to: localURL)
        Log.ipsw.notice("IPSW download complete: \(localURL.lastPathComponent, privacy: .public)")
        return localURL
    }

    // MARK: - Bundle Creation

    /// Creates a VM bundle with platform artifacts from a restore image.
    ///
    /// This generates the hardware model, machine identifier, and
    /// auxiliary storage required to install and boot macOS. The
    /// disk image is created as an empty APFS sparse file.
    ///
    /// - Parameters:
    ///   - name: The name for the VM bundle (used as directory name).
    ///   - directory: The parent directory for VM bundles.
    ///   - restoreImage: The restore image that provides the
    ///     hardware model requirements.
    ///   - spec: The hardware specification for the VM.
    /// - Returns: The newly created bundle, ready for installation.
    @MainActor
    public func createBundle(
        named name: String,
        in directory: URL,
        from restoreImage: VZMacOSRestoreImage,
        spec: VirtualMachineSpecification
    ) throws -> VirtualMachineBundle {
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            Log.ipsw.error("No supported configuration found in restore image for this host")
            throw RestoreImageError.unsupportedHost
        }
        guard requirements.hardwareModel.isSupported else {
            Log.ipsw.error("Hardware model from restore image is not supported on this Mac")
            throw RestoreImageError.unsupportedHardwareModel
        }

        Log.ipsw.info("Creating bundle '\(name, privacy: .public)' with platform artifacts")
        let bundleURL = directory.appendingPathComponent("\(name).vm")
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

        // Save hardware model.
        try requirements.hardwareModel.dataRepresentation.write(
            to: bundleURL.appendingPathComponent("hardware-model.bin")
        )

        // Generate and save a new machine identifier.
        let machineIdentifier = VZMacMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(
            to: bundleURL.appendingPathComponent("machine-identifier.bin")
        )

        // Create auxiliary storage.
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: bundleURL.appendingPathComponent("auxiliary.bin"),
            hardwareModel: requirements.hardwareModel,
            options: []
        )

        // Create empty disk image.
        let diskURL = bundleURL.appendingPathComponent("disk.img")
        try createSparseImage(at: diskURL, sizeInBytes: spec.diskSizeInBytes)

        Log.ipsw.notice("Bundle '\(name, privacy: .public)' created with platform artifacts")
        return bundle
    }

    // MARK: - Installation

    /// Installs macOS into a VM bundle from an IPSW file.
    ///
    /// This boots the VM in installation mode and writes the
    /// macOS operating system to the bundle's disk image. The
    /// process takes 10–20 minutes depending on hardware.
    ///
    /// - Parameters:
    ///   - bundle: The target VM bundle (must have platform
    ///     artifacts and an empty disk image).
    ///   - ipswURL: The local file URL of the IPSW restore image.
    ///   - progress: A closure called periodically with the
    ///     fraction completed (0.0–1.0).
    @MainActor
    public func install(
        bundle: VirtualMachineBundle,
        from ipswURL: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        Log.ipsw.info("Starting macOS installation into '\(bundle.url.lastPathComponent, privacy: .public)' from \(ipswURL.lastPathComponent, privacy: .public)")
        let config = VZVirtualMachineConfiguration()
        VirtualMachineConfiguration.applySpec(bundle.spec, to: config)
        try VirtualMachineConfiguration.applyPlatform(from: bundle, to: config)
        try VirtualMachineConfiguration.applyStorage(from: bundle, to: config)
        try config.validate()

        let vm = VZVirtualMachine(configuration: config)
        let installer = VZMacOSInstaller(
            virtualMachine: vm,
            restoringFromImageAt: ipswURL
        )

        // Observe progress.
        let observation = installer.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { progressObj, _ in
            progress(progressObj.fractionCompleted)
        }

        try await installer.install()
        observation.invalidate()
        Log.ipsw.notice("macOS installation complete for '\(bundle.url.lastPathComponent, privacy: .public)'")
    }

    // MARK: - Private

    /// Creates an empty sparse disk image file.
    ///
    /// The file is created at the specified size using `truncate`,
    /// which on APFS results in a sparse file that consumes
    /// minimal physical disk space.
    private func createSparseImage(at url: URL, sizeInBytes: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: sizeInBytes)
    }
}

// MARK: - RestoreImageError

/// An error that occurs during restore image operations.
public enum RestoreImageError: Error, Sendable, LocalizedError {
    /// The host hardware does not support the requested macOS version.
    case unsupportedHost
    /// The hardware model from the restore image is not supported.
    case unsupportedHardwareModel
    /// The host macOS version is too old to install this IPSW.
    ///
    /// The message includes both versions and guidance on how
    /// to resolve the issue. This is the same message shown by
    /// the CLI, GUI, API, and Kubernetes operator.
    case incompatibleHost(message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            "This Mac's hardware does not support the requested macOS version."
        case .unsupportedHardwareModel:
            "The hardware model from the restore image is not supported on this Mac."
        case .incompatibleHost(let message):
            message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedHost:
            "Check Apple's supported hardware list. You may need a newer Apple Silicon Mac to run this macOS version."
        case .unsupportedHardwareModel:
            "The IPSW restore image targets hardware not present on this Mac. Try downloading a different macOS version."
        case .incompatibleHost:
            "Update your Mac to a macOS version equal to or newer than the guest version, then retry."
        }
    }
}

// MARK: - DownloadProgressDelegate

/// Bridges URLSession download progress to a closure.
private final class DownloadProgressDelegate: NSObject,
    URLSessionDownloadDelegate, Sendable
{
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        handler(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Handled by the async download call.
    }
}
