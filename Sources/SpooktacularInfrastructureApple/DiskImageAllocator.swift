import Foundation
import os

/// Creates empty virtual-machine disk images in one of two
/// formats, preferring Apple Sparse Image Format (ASIF) when
/// available and falling back to RAW otherwise.
///
/// ## Why ASIF?
///
/// The Virtualization framework supports two disk-image
/// formats per
/// [`VZDiskImageStorageDeviceAttachment`](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment):
///
/// - **RAW**: a file whose byte offsets map 1-to-1 to
///   offsets in the VM disk.  On APFS the file is *sparse*
///   — unwritten extents consume no physical space — but
///   that sparseness is a host-filesystem property, not a
///   property of the file itself.  Copy a RAW-sparse `.img`
///   to an SMB / FAT32 / exFAT destination and every
///   skipped zero byte materializes.  A 64 GiB "empty" VM
///   disk becomes a literal 64 GiB transfer.
/// - **ASIF** (Apple Sparse Image Format): the sparseness
///   is encoded *inside the file's container*.  A
///   cross-filesystem copy preserves actual-data-only size.
///   Same `VZDiskImageStorageDeviceAttachment(url:)` accepts
///   it; the framework recognises the format by signature.
///
/// For portable `.spook.vm` bundles (Track B), ASIF is the
/// difference between a multi-GB tar and a MB-sized one.
/// On APFS-to-APFS transfers both formats perform
/// equivalently because Finder / `cp -c` preserve holes via
/// `clonefile(2)`, so ASIF is strictly additive.
///
/// ## Availability
///
/// `diskutil image create blank --format ASIF` shipped in
/// macOS 26.  On older hosts the subcommand fails with a
/// non-zero exit, the allocator logs and falls back to the
/// canonical RAW path from Apple's
/// [`VZDiskImageStorageDeviceAttachment` docs](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment#Create-the-disk-image)
/// (`open(2)` + `ftruncate(2)` + `close(2)`).  RAW will
/// still work — it just loses portability on
/// non-APFS destinations.
public enum DiskImageAllocator {

    /// Which on-disk format was produced.
    public enum Format: String, Sendable {
        case asif
        case raw
    }

    /// Creates an empty disk image at `url` of
    /// `sizeInBytes` bytes.  Prefers ASIF, falling back to
    /// RAW on any failure (older host, `diskutil`
    /// unavailable, `Process` spawn rejected).  Returns the
    /// format actually produced so callers can surface it
    /// in audit logs and metadata.
    ///
    /// - Parameters:
    ///   - url: Destination file URL.  Must not already
    ///     exist; caller is responsible for cleanup on
    ///     error paths.
    ///   - sizeInBytes: Disk capacity.
    ///   - preferredFormat: Format to try first.  Pass
    ///     `.raw` to skip ASIF entirely — useful for tests
    ///     and for compatibility with callers that have
    ///     already-initialized RAW expectations.
    /// - Returns: The format actually produced.
    @discardableResult
    public static func create(
        at url: URL,
        sizeInBytes: UInt64,
        preferredFormat: Format = .asif
    ) async throws -> Format {
        if preferredFormat == .asif {
            do {
                try await createASIF(at: url, sizeInBytes: sizeInBytes)
                Log.config.debug(
                    "Allocated ASIF disk \(url.lastPathComponent, privacy: .public) (\(sizeInBytes / (1024 * 1024 * 1024)) GB)"
                )
                return .asif
            } catch {
                Log.config.warning(
                    "ASIF allocation failed (\(String(describing: error), privacy: .public)); falling back to RAW."
                )
                // Clean up any partial output `diskutil` may
                // have written so the RAW fallback's
                // `O_CREAT` (without `O_EXCL`) doesn't
                // silently reuse it.
                try? FileManager.default.removeItem(at: url)
            }
        }

        try createRAW(at: url, sizeInBytes: sizeInBytes)
        Log.config.debug(
            "Allocated RAW disk \(url.lastPathComponent, privacy: .public) (\(sizeInBytes / (1024 * 1024 * 1024)) GB)"
        )
        return .raw
    }

    // MARK: - ASIF

    /// Invokes `diskutil image create blank --format ASIF`
    /// and waits for exit via `Process.terminationHandler`
    /// bridged to a checked continuation.  `--fs none`
    /// skips the APFS-volume-inside-the-image step — the
    /// guest's installer writes the filesystem itself.
    ///
    /// Ordering: `terminationHandler` is installed *before*
    /// `run()` to close a race where `diskutil` could exit
    /// between those two calls and leave the continuation
    /// un-resumed.  Apple's `Process` docs note the handler
    /// is `@Sendable`, so resuming the continuation from
    /// inside it across isolation domains is safe.
    ///
    /// Sizing caveat: `diskutil image create blank` rounds
    /// `--size` down to a 512-byte sector boundary — the
    /// `B` byte-suffix is accepted syntactically but the
    /// resulting virtual capacity is `(sizeInBytes / 512)
    /// * 512`.  All production callers pass
    /// `spec.diskSizeInBytes` computed from `.gigabytes(N)`
    /// which is always `N * 1,073,741,824` bytes
    /// (= `N * 2,097,152 * 512`), so the rounding is a
    /// no-op for us.  For arbitrary byte counts, the
    /// ``createRAW(at:sizeInBytes:)`` fallback path using
    /// `ftruncate(2)` *is* byte-exact, which is a benign
    /// inconsistency at today's call sites but worth
    /// knowing if future callers request non-sector-aligned
    /// sizes.
    private static func createASIF(
        at url: URL,
        sizeInBytes: UInt64
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = [
            "image", "create", "blank",
            "--fs", "none",
            "--format", "ASIF",
            "--size", "\(sizeInBytes)B",
            url.path
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        let exitCode: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                // `run()` threw — the termination handler
                // will never fire, so clear it to prevent a
                // double-resume if the handler somehow did
                // get scheduled, and fail the continuation
                // with the launch error.
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }

        guard exitCode == 0 else {
            let stderr = (try? stderrPipe.fileHandleForReading.readToEnd())
                .flatMap { $0 }
                .flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            throw DiskImageAllocatorError.diskutilFailed(
                exitCode: exitCode,
                stderr: stderr
            )
        }
    }

    // MARK: - RAW

    /// Matches Apple's canonical pattern from
    /// [`VZDiskImageStorageDeviceAttachment` — Create the disk image](https://developer.apple.com/documentation/virtualization/vzdiskimagestoragedeviceattachment#Create-the-disk-image):
    /// `open(O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)` followed
    /// by `ftruncate` to the requested capacity.  APFS
    /// handles the sparse-extent semantics so the file
    /// consumes ~zero bytes at rest, only growing as the
    /// guest writes.
    private static func createRAW(
        at url: URL,
        sizeInBytes: UInt64
    ) throws {
        let fd = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd != -1 else {
            throw DiskImageAllocatorError.openFailed(
                path: url.path,
                errno: String(cString: strerror(errno))
            )
        }
        let ftruncResult = ftruncate(fd, off_t(sizeInBytes))
        let truncateErrno = errno
        close(fd)
        guard ftruncResult == 0 else {
            throw DiskImageAllocatorError.truncateFailed(
                path: url.path,
                errno: String(cString: strerror(truncateErrno))
            )
        }
    }
}

/// Errors produced by ``DiskImageAllocator``.
public enum DiskImageAllocatorError: Error, Sendable, LocalizedError {
    case diskutilFailed(exitCode: Int32, stderr: String)
    case openFailed(path: String, errno: String)
    case truncateFailed(path: String, errno: String)

    public var errorDescription: String? {
        switch self {
        case let .diskutilFailed(exitCode, stderr):
            let tail = stderr.isEmpty ? "" : ": \(stderr)"
            return "`diskutil image create blank` exited \(exitCode)\(tail)"
        case let .openFailed(path, err):
            return "Failed to open '\(path)' for disk-image allocation: \(err)"
        case let .truncateFailed(path, err):
            return "ftruncate() failed on '\(path)': \(err)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .diskutilFailed:
            return "Check free disk space and that the target directory is writable. On macOS versions earlier than 26, ASIF is unavailable and the allocator falls back to RAW automatically."
        case .openFailed, .truncateFailed:
            return "Check free disk space and filesystem permissions on the target directory."
        }
    }
}
