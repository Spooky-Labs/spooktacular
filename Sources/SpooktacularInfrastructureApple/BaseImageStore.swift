import Foundation
import os

/// What a built base image is, and when it was made.
///
/// Persisted as `base.json` beside the image so a base can be
/// validated, reported and rebuilt without opening the disk image
/// itself.
public struct BaseImageDescriptor: Sendable, Codable, Equatable {

    /// The macOS build this base was installed from, for example `27A5301a`.
    public let buildVersion: String

    /// The base layer's UUID, recorded by every VM that stacks on it.
    public let layerUUID: UUID

    /// Logical size of the base image in bytes.
    public let sizeInBytes: UInt64

    /// When the base finished building.
    public let createdAt: Date

    /// Version of the provisioner assets baked into the base, so a
    /// changed provisioner invalidates stale bases instead of being
    /// silently absent from VMs created against them.
    public let provisionerVersion: String

    /// Creates a descriptor.
    ///
    /// - Parameters:
    ///   - buildVersion: The macOS build string.
    ///   - layerUUID: The base image's layer UUID.
    ///   - sizeInBytes: Logical image size.
    ///   - createdAt: Build completion time.
    ///   - provisionerVersion: Version of the injected provisioner.
    public init(
        buildVersion: String,
        layerUUID: UUID,
        sizeInBytes: UInt64,
        createdAt: Date,
        provisionerVersion: String
    ) {
        self.buildVersion = buildVersion
        self.layerUUID = layerUUID
        self.sizeInBytes = sizeInBytes
        self.createdAt = createdAt
        self.provisionerVersion = provisionerVersion
    }
}

/// The on-disk cache of installed-once macOS base images.
///
/// ## Cache Layout
///
/// ```
/// ~/.spooktacular/cache/base/
/// └── <macOS build>/
///     ├── base.asif          ← installed once, sealed read-only, never booted
///     ├── auxiliary.bin      ← cloned per VM
///     ├── hardware-model.bin
///     ├── base.json          ← BaseImageDescriptor
///     └── .build.lock        ← serializes concurrent builds
/// ```
///
/// This type owns paths, the descriptor file and the build lock.
/// Producing a base is ``BaseImageBuilder``'s job.
public final class BaseImageStore: Sendable {

    /// The directory holding all per-build subdirectories.
    public let rootDirectory: URL

    private static let log = Logger(subsystem: "com.spooktacular", category: "base-image")

    /// Creates a store rooted at a directory.
    ///
    /// - Parameter rootDirectory: Typically ``SpooktacularPaths/baseImages``.
    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    /// The directory for one macOS build.
    ///
    /// - Parameter build: The macOS build string.
    public func directory(forBuild build: String) -> URL {
        rootDirectory.appendingPathComponent(build, isDirectory: true)
    }

    /// The base image file for a build.
    ///
    /// - Parameter build: The macOS build string.
    public func baseImageURL(forBuild build: String) -> URL {
        directory(forBuild: build).appendingPathComponent("base.asif")
    }

    /// The auxiliary-storage template for a build.
    ///
    /// - Parameter build: The macOS build string.
    public func auxiliaryStorageURL(forBuild build: String) -> URL {
        directory(forBuild: build).appendingPathComponent("auxiliary.bin")
    }

    /// The serialized hardware model for a build.
    ///
    /// - Parameter build: The macOS build string.
    public func hardwareModelURL(forBuild build: String) -> URL {
        directory(forBuild: build).appendingPathComponent("hardware-model.bin")
    }

    /// The machine identifier the base was installed with.
    ///
    /// The installer personalizes the auxiliary storage against this
    /// identity, so every VM overlaid on the base must reuse it — see
    /// ``VirtualMachineBundle/createOverlayBacked(at:spec:displayName:base:baseImageURL:baseAuxiliaryURL:baseHardwareModelURL:baseMachineIdentifierURL:network:publications:)``.
    ///
    /// - Parameter build: The macOS build string.
    public func machineIdentifierURL(forBuild build: String) -> URL {
        directory(forBuild: build).appendingPathComponent("machine-identifier.bin")
    }

    /// The descriptor file for a build.
    ///
    /// - Parameter build: The macOS build string.
    public func descriptorURL(forBuild build: String) -> URL {
        directory(forBuild: build).appendingPathComponent("base.json")
    }

    /// Reads a build's descriptor.
    ///
    /// - Parameter build: The macOS build string.
    /// - Returns: The descriptor, or `nil` when none has been written.
    /// - Throws: ``BaseImageStoreError/descriptorUnreadable(_:)`` when
    ///   the file exists but cannot be decoded.
    public func descriptor(forBuild build: String) throws -> BaseImageDescriptor? {
        let url = descriptorURL(forBuild: build)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try VirtualMachineBundle.decoder.decode(BaseImageDescriptor.self, from: data)
        } catch {
            throw BaseImageStoreError.descriptorUnreadable(url)
        }
    }

    /// Writes a descriptor, creating the build directory if needed.
    ///
    /// - Parameter descriptor: The descriptor to persist.
    /// - Throws: A file-system or encoding error.
    public func write(_ descriptor: BaseImageDescriptor) throws {
        let directory = directory(forBuild: descriptor.buildVersion)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try VirtualMachineBundle.encoder.encode(descriptor)
        try data.write(to: descriptorURL(forBuild: descriptor.buildVersion), options: .atomic)
    }

    /// Whether a usable base exists for a build.
    ///
    /// Requires both the descriptor and the image file, so a build
    /// interrupted after writing one but not the other is treated as
    /// absent and rebuilt rather than half-trusted.
    ///
    /// - Parameter build: The macOS build string.
    public func hasBase(forBuild build: String) -> Bool {
        let descriptorExists = FileManager.default.fileExists(
            atPath: descriptorURL(forBuild: build).path
        )
        let imageExists = FileManager.default.fileExists(atPath: baseImageURL(forBuild: build).path)
        return descriptorExists && imageExists
    }

    /// The macOS builds that currently have a complete base image.
    ///
    /// - Returns: Build strings, sorted, or an empty array when the
    ///   cache directory does not exist yet.
    public func availableBuilds() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .map(\.lastPathComponent)
            .filter { hasBase(forBuild: $0) }
            .sorted()
    }

    /// Runs `body` while holding this build's exclusive lock.
    ///
    /// Two `spook create` invocations racing on a cold cache must not
    /// both run a 20-minute install: the loser blocks here until the
    /// winner finishes, then finds the base already present.
    ///
    /// The body is `async` because building a base awaits the
    /// installer. A POSIX file lock is held by the process, not the
    /// thread, so it remains valid across suspension points.
    ///
    /// - Parameters:
    ///   - build: The macOS build string.
    ///   - body: Work to perform under the lock.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Rethrows `body`'s error, or
    ///   ``BaseImageStoreError/lockUnavailable(_:)`` when the lock file
    ///   cannot be created or acquired.
    public func withBuildLock<T>(
        forBuild build: String,
        _ body: () async throws -> T
    ) async throws -> T {
        let directory = directory(forBuild: build)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".build.lock")

        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            throw BaseImageStoreError.lockUnavailable(lockURL)
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            throw BaseImageStoreError.lockUnavailable(lockURL)
        }
        defer { _ = flock(descriptor, LOCK_UN) }

        return try await body()
    }
}

/// Diagnostics for the base-image cache.
public enum BaseImageStoreError: Error, Sendable, Equatable, LocalizedError {

    /// A descriptor file exists but could not be decoded.
    case descriptorUnreadable(URL)

    /// The build lock could not be created or acquired.
    case lockUnavailable(URL)

    /// A build directory exists but is missing required files.
    case incomplete(build: String)

    public var errorDescription: String? {
        switch self {
        case .descriptorUnreadable(let url):
            "Could not read the base-image descriptor at '\(url.path)'."
        case .lockUnavailable(let url):
            "Could not acquire the base-image build lock at '\(url.path)'."
        case .incomplete(let build):
            "The cached base image for macOS build \(build) is incomplete."
        }
    }

    public var recoverySuggestion: String? {
        "Delete the affected directory under ~/.spooktacular/cache/base/ and create a VM again to rebuild it."
    }
}
