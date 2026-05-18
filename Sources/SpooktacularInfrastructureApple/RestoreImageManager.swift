import Foundation
import CryptoKit
import SpooktacularCore
import SpooktacularApplication
import os
@preconcurrency import Virtualization

// MARK: - Progress Payload

/// A snapshot of an in-flight IPSW download.
///
/// Surfaced to UI bindings via the `progress` callback. The UI
/// layer derives a percentage, ETA, or byte-count label from
/// whichever fields it wants to display.
public struct DownloadProgress: Sendable {
    /// Total bytes received so far (including resumed bytes).
    public let bytesReceived: Int64
    /// Expected total size of the download.
    public let bytesTotal: Int64
    /// Whether the download was resumed from a partial cache file.
    public let resumed: Bool

    /// Fraction complete in `0.0...1.0`. Returns `0.0` when the
    /// total is unknown to keep UI bindings finite.
    public var fraction: Double {
        guard bytesTotal > 0 else { return 0.0 }
        return min(1.0, Double(bytesReceived) / Double(bytesTotal))
    }

    /// Creates a progress snapshot.
    public init(bytesReceived: Int64, bytesTotal: Int64, resumed: Bool) {
        self.bytesReceived = bytesReceived
        self.bytesTotal = bytesTotal
        self.resumed = resumed
    }
}

/// Manages macOS restore images (IPSWs) for virtual machine installation.
///
/// `RestoreImageManager` handles downloading, caching, and installing
/// macOS from Apple's IPSW restore images. Downloaded images are
/// cached by SHA256 content hash — the filename on disk is the
/// hex-encoded hash, so two URLs that point to the same bytes
/// share a single cache entry.
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
/// ├── <sha256>.ipsw       ← validated complete download
/// └── <sha256>.ipsw.part  ← in-flight / resumable partial
/// ```
///
/// Cached files are validated against their filename hash before
/// use — a corrupted cache entry is deleted and re-downloaded
/// rather than silently returned.
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
    /// Implements HTTP Range (RFC 7233) resumption keyed by SHA256
    /// content hash:
    ///
    /// 1. Probe the server with a HEAD for `Content-Length`,
    ///    `ETag`, and `Accept-Ranges`.
    /// 2. If the response advertises `Accept-Ranges: bytes` and a
    ///    matching `.part` file exists, request only the tail
    ///    using `Range: bytes=<offset>-` plus `If-Range: <etag>`
    ///    so the server revalidates the partial.
    /// 3. Stream bytes to the `.part` file.
    /// 4. On completion, hash the finished file; rename to
    ///    `<sha256>.ipsw`. If a sibling with that hash already
    ///    exists (same content via a different URL), deduplicate.
    ///
    /// Transient failures (network timeout, connection reset)
    /// retry up to four times with exponential backoff
    /// (1s, 2s, 4s, 8s). Cancellation via `Task.cancel()`
    /// preserves the `.part` file so the next invocation
    /// resumes rather than redownloading.
    ///
    /// - Parameters:
    ///   - restoreImage: The restore image to download.
    ///   - progress: A closure called periodically with a
    ///     ``DownloadProgress`` snapshot (bytes, total, resumed).
    /// - Returns: The local file URL of the downloaded IPSW,
    ///   whose filename is the hex SHA256 of the file contents.
    public func downloadIPSW(
        from restoreImage: VZMacOSRestoreImage,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        // First, attempt to find an existing validated cache entry.
        // We can't know the SHA in advance, so we scan existing
        // finished files matching the URL's byte-length; if none
        // matches we fall through to a fresh download.
        let source = restoreImage.url
        Log.ipsw.info("Preparing IPSW download from \(source.lastPathComponent, privacy: .public)")

        // Probe via HEAD to pick up Content-Length + ETag.
        let probe = try await probeRemote(url: source)

        // Scan for any finished file whose hash filename matches —
        // for a hit, we're done. We cannot know the hash until the
        // file is complete, so identity is by-size heuristic plus
        // verify-on-read. Safer: always verify cached hash against
        // the filename.
        if let hit = try findValidatedCacheEntry(matchingSize: probe.contentLength) {
            Log.ipsw.info("Cached IPSW already valid at \(hit.lastPathComponent, privacy: .public)")
            progress(DownloadProgress(
                bytesReceived: probe.contentLength,
                bytesTotal: probe.contentLength,
                resumed: true
            ))
            return hit
        }

        // Use a URL-derived stable partial key so resumption across
        // invocations works. The final rename to SHA256 happens
        // post-hash.
        let partURL = cacheDirectory
            .appendingPathComponent("in-progress-\(partialKey(for: source)).part")

        let finished = try await downloadWithRetry(
            from: source,
            probe: probe,
            partFile: partURL,
            progress: progress
        )

        // Hash and rename to <sha256>.ipsw so identical content
        // from any URL deduplicates.
        let digest = try sha256(of: finished)
        let finalURL = cacheDirectory.appendingPathComponent("\(digest).ipsw")

        if fileManager.fileExists(atPath: finalURL.path) {
            // Someone raced us with the same content. Validate the
            // existing file, drop the duplicate.
            if try verifyFileHash(at: finalURL, expected: digest) {
                try? fileManager.removeItem(at: finished)
                Log.ipsw.notice("Deduplicated IPSW against existing cache entry \(digest, privacy: .public)")
                return finalURL
            }
            try fileManager.removeItem(at: finalURL)
        }
        try fileManager.moveItem(at: finished, to: finalURL)
        Log.ipsw.notice("IPSW download complete: \(finalURL.lastPathComponent, privacy: .public)")
        return finalURL
    }

    // MARK: - Download Internals

    /// Metadata harvested from a HEAD probe.
    private struct RemoteProbe: Sendable {
        let contentLength: Int64
        let etag: String?
        let acceptsRanges: Bool
    }

    /// Issues a HEAD request to discover size, ETag, and range
    /// support before starting (or resuming) a download.
    private func probeRemote(url: URL) async throws -> RemoteProbe {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 30
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RestoreImageError.downloadFailed(message: "HEAD probe returned non-HTTP response")
        }
        let length = http.expectedContentLength > 0 ? http.expectedContentLength : 0
        let etag = http.value(forHTTPHeaderField: "ETag")
        let accept = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased()
        return RemoteProbe(
            contentLength: length,
            etag: etag,
            acceptsRanges: accept == "bytes"
        )
    }

    /// Drives the resumable download loop with exponential backoff.
    private func downloadWithRetry(
        from source: URL,
        probe: RemoteProbe,
        partFile: URL,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        let fileManager = FileManager.default
        let maxAttempts = 4
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            attempt += 1
            do {
                // If we have a partial and the server supports
                // Range + has a matching ETag, resume; otherwise
                // restart from zero.
                var offset: Int64 = 0
                if fileManager.fileExists(atPath: partFile.path) {
                    let size = (try? fileManager.attributesOfItem(atPath: partFile.path))?[.size] as? NSNumber
                    offset = size?.int64Value ?? 0
                    if !probe.acceptsRanges || offset == 0 || offset >= probe.contentLength {
                        // Can't resume — start over.
                        try? fileManager.removeItem(at: partFile)
                        offset = 0
                    }
                }

                try await streamBytes(
                    from: source,
                    probe: probe,
                    partFile: partFile,
                    startOffset: offset,
                    progress: progress
                )

                return partFile
            } catch is CancellationError {
                // Preserve partial for later resumption.
                throw CancellationError()
            } catch {
                lastError = error
                Log.ipsw.warning(
                    "IPSW download attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
                if attempt >= maxAttempts { break }
                let delay = UInt64(pow(2.0, Double(attempt - 1))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }

        throw RestoreImageError.downloadFailed(
            message: lastError?.localizedDescription ?? "Download failed after \(maxAttempts) attempts"
        )
    }

    /// Streams the remote file into `partFile`, appending at
    /// `startOffset` when resuming.
    private func streamBytes(
        from source: URL,
        probe: RemoteProbe,
        partFile: URL,
        startOffset: Int64,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        var request = URLRequest(url: source)
        request.timeoutInterval = 120
        let resuming = startOffset > 0
        if resuming {
            request.setValue("bytes=\(startOffset)-", forHTTPHeaderField: "Range")
            if let etag = probe.etag {
                // If-Range: server either honors the partial or
                // returns the full 200 OK with the new content.
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            }
        }

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RestoreImageError.downloadFailed(message: "Non-HTTP response during body fetch")
        }

        let fileManager = FileManager.default
        let appending: Bool
        switch http.statusCode {
        case 206:
            appending = resuming
        case 200:
            // Server ignored or invalidated our partial.
            appending = false
            try? fileManager.removeItem(at: partFile)
        default:
            throw RestoreImageError.downloadFailed(message: "Server returned HTTP \(http.statusCode)")
        }

        if !fileManager.fileExists(atPath: partFile.path) {
            fileManager.createFile(atPath: partFile.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: partFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if !appending {
            try handle.truncate(atOffset: 0)
        }

        let total = probe.contentLength > 0 ? probe.contentLength : http.expectedContentLength
        var received: Int64 = appending ? startOffset : 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        for try await byte in bytes {
            if Task.isCancelled { throw CancellationError() }
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                progress(DownloadProgress(
                    bytesReceived: received,
                    bytesTotal: total,
                    resumed: appending
                ))
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            progress(DownloadProgress(
                bytesReceived: received,
                bytesTotal: total,
                resumed: appending
            ))
        }
    }

    /// Returns a stable cache filename seed for an in-progress
    /// download. We use the URL's last path component — it doesn't
    /// have to be the final hash, just stable across invocations
    /// so resumption finds the partial.
    private func partialKey(for url: URL) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(url.absoluteString.utf8))
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns the first cached IPSW whose filename matches its
    /// content hash AND whose byte length matches the HEAD probe.
    ///
    /// A content-hash mismatch signals corruption; such a file is
    /// deleted and `nil` is returned so the caller re-downloads.
    private func findValidatedCacheEntry(matchingSize expectedSize: Int64) throws -> URL? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheDirectory.path) else { return nil }
        let contents = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        for url in contents where url.pathExtension == "ipsw" {
            let base = url.deletingPathExtension().lastPathComponent
            // Must look like a hex SHA256 (64 chars).
            guard base.count == 64, base.allSatisfy({ $0.isHexDigit }) else { continue }

            if expectedSize > 0 {
                let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
                guard let size, size.int64Value == expectedSize else { continue }
            }

            if try verifyFileHash(at: url, expected: base) {
                return url
            } else {
                Log.ipsw.warning("Deleting corrupted cache entry: \(url.lastPathComponent, privacy: .public)")
                try? fileManager.removeItem(at: url)
            }
        }
        return nil
    }

    /// Computes the hex-encoded SHA256 hash of a file on disk.
    internal func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Returns `true` when the file at `url` hashes to the expected
    /// hex-encoded SHA256 digest.
    internal func verifyFileHash(at url: URL, expected: String) throws -> Bool {
        let actual = try sha256(of: url)
        return actual.caseInsensitiveCompare(expected) == .orderedSame
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
    ) async throws -> VirtualMachineBundle {
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

        try requirements.hardwareModel.dataRepresentation.write(
            to: bundleURL.appendingPathComponent(VirtualMachineBundle.hardwareModelFileName)
        )

        let machineIdentifier = VZMacMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(
            to: bundleURL.appendingPathComponent(VirtualMachineBundle.machineIdentifierFileName)
        )

        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: bundleURL.appendingPathComponent(VirtualMachineBundle.auxiliaryStorageFileName),
            hardwareModel: requirements.hardwareModel,
            options: []
        )

        let diskURL = bundleURL.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
        let diskFormat = try await DiskImageAllocator.create(
            at: diskURL,
            sizeInBytes: spec.diskSizeInBytes
        )

        Log.ipsw.notice("Bundle '\(name, privacy: .public)' created with platform artifacts (disk format: \(diskFormat.rawValue.uppercased(), privacy: .public))")
        return bundle
    }

    // MARK: - Installation

    /// Installs macOS into a VM bundle from an IPSW file.
    ///
    /// This boots the VM in installation mode and writes the
    /// macOS operating system to the bundle's disk image. The
    /// process takes 10–20 minutes depending on hardware.
    ///
    /// - Important: Callers **must** call ``fetchLatestSupported()``
    ///   before invoking this method. `fetchLatestSupported` verifies
    ///   that the host macOS version is compatible with the IPSW.
    ///   Skipping that check may result in an opaque Virtualization
    ///   framework error during installation.
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
        try VirtualMachineConfiguration.applySpec(bundle.spec, to: config)
        try VirtualMachineConfiguration.applyPlatform(from: bundle, to: config)
        try VirtualMachineConfiguration.applyStorage(from: bundle, to: config)
        try config.validate()

        let vm = VZVirtualMachine(configuration: config)
        let installer = VZMacOSInstaller(
            virtualMachine: vm,
            restoringFromImageAt: ipswURL
        )

        // Observe progress. Use `defer` for the invalidation so it
        // also runs when `install()` throws — otherwise the KVO
        // observation leaks until `installer` deallocates.
        let observation = installer.progress.observe(
            \.fractionCompleted,
            options: [.new]
        ) { progressObj, _ in
            progress(progressObj.fractionCompleted)
        }
        defer { observation.invalidate() }

        try await installer.install()
        Log.ipsw.notice("macOS installation complete for '\(bundle.url.lastPathComponent, privacy: .public)'")
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
    /// The IPSW download failed after all retry attempts, or the
    /// server returned an unusable response (non-2xx/206).
    case downloadFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedHost:
            "This Mac's hardware does not support the requested macOS version."
        case .unsupportedHardwareModel:
            "The hardware model from the restore image is not supported on this Mac."
        case .incompatibleHost(let message):
            message
        case .downloadFailed(let message):
            "IPSW download failed: \(message)"
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
        case .downloadFailed:
            "Check your network connection and retry. Partial downloads resume automatically."
        }
    }
}
