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
                    // `offset >= contentLength` also covers contentLength == 0,
                    // i.e. a HEAD that told us nothing: resuming against an
                    // unknown total cannot be validated, so start clean.
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

                // A stream that ends early is not an error on its own: the
                // loop above simply stops receiving bytes. Without this
                // check the partial was returned as a finished download,
                // promoted to the cache, and handed to VZMacOSInstaller,
                // which failed at 0% with "An error occurred during
                // installation" — an error that says nothing about the real
                // cause. Measure the file instead of trusting the loop.
                if probe.contentLength > 0 {
                    let finalSize = ((try? fileManager.attributesOfItem(atPath: partFile.path))?[.size] as? NSNumber)?.int64Value ?? 0
                    guard finalSize == probe.contentLength else {
                        // Keep the partial: the next attempt resumes from here.
                        throw RestoreImageError.downloadFailed(
                            message: "Incomplete download: got \(finalSize) of \(probe.contentLength) bytes"
                        )
                    }
                }

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

    /// Public entry point onto ``waitForPlatformArtifactsReleased(bundle:ceiling:pollInterval:)``
    /// for callers outside this file that are about to attach to a
    /// bundle's `disk.img` right after force-stopping a
    /// `VirtualMachine` built against it — the same lingering VZ
    /// XPC-service lock this type already waits out for its own
    /// post-install callers (see that method's doc comment for the
    /// full `lsof`-confirmed root cause).
    ///
    /// Used by `spooktacular-cli`'s `Create` command: after
    /// `DiskInjector.installProvisionerDaemon` attaches/detaches this
    /// same bundle's `disk.img`, `DiskInjector.installGuestTools`
    /// shells straight to `diskutil image attach` on it again with
    /// no pre-flight of its own — exactly the race this wait exists
    /// to close.
    public static func waitForArtifactsReleased(
        bundle: VirtualMachineBundle,
        ceiling: TimeInterval = 30,
        pollInterval: TimeInterval = 0.25
    ) async {
        await waitForPlatformArtifactsReleased(bundle: bundle, ceiling: ceiling, pollInterval: pollInterval)
    }

    /// Waits for the bundle's platform artifact files (auxiliary
    /// storage, disk image) to no longer be held open by another
    /// process, or for `ceiling` to elapse — whichever comes first.
    ///
    /// ## Why this exists
    ///
    /// `VZVirtualMachine` does not perform virtualization in-process:
    /// Apple's Virtualization.framework delegates the actual device
    /// I/O for a VM to a separate, independently-lived XPC service,
    /// `com.apple.Virtualization.VirtualMachine.xpc`. Releasing our
    /// Swift reference to a `VZVirtualMachine` (as ``runInstaller``
    /// does, deterministically, the moment it returns) only asks
    /// that service to tear down; the service's own exit — which is
    /// what actually closes its file descriptors on `auxiliary.bin`
    /// / `disk.img` and releases the advisory lock that
    /// `VZMacAuxiliaryStorage(contentsOf:)` and
    /// `VZDiskImageStorageDeviceAttachment(url:)` require for the
    /// NEXT `VirtualMachine` constructed against the same bundle —
    /// happens on its own schedule. Neither `VZMacOSInstaller` nor
    /// `VZVirtualMachine` expose a signal to await that exit.
    ///
    /// Confirmed empirically while diagnosing the absence of this
    /// method (no in-process fix exists — this is not a reference-
    /// retention bug):
    ///   - Constructing a new `VirtualMachine` immediately after
    ///     `install()` returned threw "Failed to lock auxiliary
    ///     storage" — reproduced twice live, still failing after
    ///     ~7s of retry backoff.
    ///   - `lsof <bundle>/auxiliary.bin` during that window showed
    ///     the file held open by
    ///     `com.apple.Virtualization.VirtualMachine.xpc` running as
    ///     its OWN process (`ps`: distinct PID, PPID 1) — not by our
    ///     CLI/GUI process. This rules out in-process retention:
    ///     nothing in ``runInstaller`` keeps `vm` / `installer` alive
    ///     past its own return.
    ///   - `kill -9` on that XPC PID released the lock within the
    ///     same `lsof` poll — the lock's lifetime is exactly that
    ///     process's lifetime, not a background timer our own
    ///     dealloc could accelerate.
    ///   - A brand-new process constructing a `VirtualMachine` on
    ///     the SAME (otherwise idle) bundle succeeded and booted
    ///     immediately — nothing was permanently stuck; the delay is
    ///     purely the OLD XPC service's own asynchronous teardown.
    ///
    /// With no deterministic release signal available, this polls
    /// the one thing that IS observable — whether `lsof` still shows
    /// the file open — instead of guessing a fixed sleep or retrying
    /// blind construction attempts against an undocumented, possibly
    /// localized error string. The 30s ceiling mirrors the same
    /// order of magnitude already observed for the analogous
    /// `disk.img` post-Stop hold in the GUI (`AppState.isDiskInUse`,
    /// commit 30413e5e1: "lingers for 5–30 seconds"). If the ceiling
    /// is hit, this logs and returns anyway rather than throwing —
    /// callers that construct a `VirtualMachine` right after
    /// `install()` carry their own small residual retry for exactly
    /// that unlikely case (see `VirtualMachine.makeAfterInstall(bundle:onRetry:)`).
    private static func waitForPlatformArtifactsReleased(
        bundle: VirtualMachineBundle,
        ceiling: TimeInterval = 30,
        pollInterval: TimeInterval = 0.25
    ) async {
        let paths = [
            bundle.url.appendingPathComponent(VirtualMachineBundle.auxiliaryStorageFileName).path,
            bundle.url.appendingPathComponent(VirtualMachineBundle.diskImageFileName).path
        ]
        let deadline = Date().addingTimeInterval(ceiling)
        while Date() < deadline {
            if !paths.contains(where: isHeldOpenByAnotherProcess) {
                return
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        Log.ipsw.warning(
            "Platform artifacts for '\(bundle.url.lastPathComponent, privacy: .public)' still held open after \(ceiling, privacy: .public)s wait; proceeding anyway."
        )
    }

    /// Returns `true` if `lsof` reports any process OTHER than this
    /// one holding `path` open. Same job as the GUI's
    /// `AppState.isDiskInUse` pre-flight (commit 30413e5e1), hoisted
    /// here so the CLI and GUI post-install paths share one
    /// implementation — but PID-aware: a handle held by OUR OWN
    /// process is not the XPC lock this probe exists to detect (the
    /// XPC service is a separate process; a same-process handle
    /// wouldn't block `VirtualMachine` construction the same way, and
    /// counting it would silently degrade every install to the full
    /// wait ceiling). `lsof -F p` emits one `p<PID>` line per holding
    /// process, which is machine-parseable — no header-line
    /// heuristics against localized column output.
    ///
    /// `internal` rather than `private` — unlike the VZ-framework
    /// calls elsewhere in this file, this is a plain `lsof` wrapper
    /// with no Apple-entitlement or network dependency, so it's
    /// exercisable directly from `@testable import
    /// SpooktacularInfrastructureApple` (see `RestoreImageManagerTests`)
    /// the same way ``sha256(of:)`` / ``verifyFileHash(at:expected:)``
    /// already are.
    static func isHeldOpenByAnotherProcess(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -F p: field output, one "p<PID>" line per process holding
        // the file open. Exits non-zero with empty output when no
        // process holds it.
        process.arguments = ["-F", "p", path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }
            let ownPID = ProcessInfo.processInfo.processIdentifier
            return output.split(separator: "\n").contains { line in
                guard line.first == "p", let pid = Int32(line.dropFirst()) else { return false }
                return pid != ownPID
            }
        } catch {
            // lsof unavailable — skip the check and let the actual
            // construction attempt surface the real error, if any.
            return false
        }
    }

}

// MARK: - RestoreImageError

/// An error that occurs during restore image operations.
public enum RestoreImageError: Error, Sendable, LocalizedError {
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
        case .incompatibleHost(let message):
            message
        case .downloadFailed(let message):
            "IPSW download failed: \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .incompatibleHost:
            "Update your Mac to a macOS version equal to or newer than the guest version, then retry."
        case .downloadFailed:
            "Check your network connection and retry. Partial downloads resume automatically."
        }
    }
}
