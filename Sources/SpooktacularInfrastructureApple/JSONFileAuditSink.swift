import Foundation
import SpooktacularCore
import SpooktacularApplication

/// Appends audit records as JSON lines to a file, with daily and
/// size-based rotation.
///
/// Each record is a single JSON object on one line (JSONL format),
/// suitable for ingestion by Splunk, Elasticsearch, CloudWatch Logs,
/// or any SIEM that supports structured JSON log files.
///
/// ## Rotation
///
/// The sink rotates on two triggers, whichever fires first:
///
/// 1. **Daily** — at the first write on a new UTC day, the current
///    file is closed and renamed to `<basename>.<YYYY-MM-DD>.jsonl`.
/// 2. **Size** — when the current file exceeds ``rotationBytes``
///    (default 1 GiB), the file is closed and renamed to
///    `<basename>.<YYYY-MM-DD>.<HHMMSS>.jsonl`.
///
/// Rotated files are left in the same directory; callers are
/// expected to ship or compress them via `logrotate`, `newsyslog`,
/// an OS cron job, or an external SIEM forwarder. The sink does
/// not gzip rotated files itself — writing compression here would
/// pin Foundation's `Compression` framework onto this layer and
/// defeat SIEM agents that expect plaintext.
///
/// ## Durability
///
/// Each write is `fsync`'d before ``record(_:)`` returns (via
/// ``FileHandle/synchronize()``), matching the contract of
/// ``AppendOnlyFileAuditStore``. A write that returns normally is
/// guaranteed to survive a power loss / kernel panic up to the
/// guarantees of the underlying APFS container.
///
/// ## Usage
///
/// ```swift
/// let sink = try JSONFileAuditSink(path: "/var/log/spooktacular/audit.jsonl")
/// try await sink.record(auditEntry)
/// ```
public actor JSONFileAuditSink: AuditSink {

    /// Default rotation threshold: 1 GiB.
    public static let defaultRotationBytes: UInt64 = 1 << 30

    private let basePath: String
    private let rotationBytes: UInt64
    private let encoder: JSONEncoder

    private var fileHandle: FileHandle
    private var currentDay: DateComponents
    private var bytesWritten: UInt64

    /// Creates an audit sink that writes to the given file path.
    /// Creates the file and any missing parent directories.
    ///
    /// - Parameters:
    ///   - path: Absolute path to the audit file. `.jsonl` suffix
    ///     is conventional but not enforced.
    ///   - rotationBytes: Size in bytes at which the current file
    ///     is rotated. Defaults to 1 GiB. Pass `UInt64.max` to
    ///     disable size-based rotation (daily rotation still runs).
    /// - Throws: ``AuditSinkError`` if the file cannot be opened
    ///   for appending.
    public init(
        path: String,
        rotationBytes: UInt64 = JSONFileAuditSink.defaultRotationBytes
    ) throws {
        self.basePath = path
        self.rotationBytes = rotationBytes

        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw AuditSinkError.recordingFailed(reason: "cannot open audit file for writing: \(path)")
        }
        try handle.seekToEnd()
        self.fileHandle = handle

        let attrs = (try? fm.attributesOfItem(atPath: path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        self.bytesWritten = size

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc

        self.currentDay = JSONFileAuditSink.utcDay(of: Date())
    }

    // MARK: - AuditSink

    public func record(_ entry: AuditRecord) async throws {
        try rotateIfNeeded(now: Date())

        let data: Data
        do {
            var encoded = try encoder.encode(entry)
            encoded.append(0x0A) // newline
            data = encoded
        } catch {
            throw AuditSinkError.recordingFailed(reason: "encode failed: \(error.localizedDescription)")
        }

        do {
            try fileHandle.write(contentsOf: data)
            // `synchronize()` issues fsync(2) on the underlying
            // file descriptor — the file is on durable storage
            // before we return. Dropping this call would reduce
            // every AuditSink guarantee to "in-memory best effort"
            // and break AU-9 (protection of audit information).
            try fileHandle.synchronize()
        } catch {
            throw AuditSinkError.recordingFailed(reason: "write failed: \(error.localizedDescription)")
        }
        bytesWritten += UInt64(data.count)
    }

    // MARK: - Rotation

    private func rotateIfNeeded(now: Date) throws {
        let day = JSONFileAuditSink.utcDay(of: now)
        let dayChanged = day != currentDay
        let sizeExceeded = bytesWritten >= rotationBytes
        guard dayChanged || sizeExceeded else { return }

        try rotate(stamp: now, reason: sizeExceeded ? .size : .daily)
        currentDay = day
    }

    private enum RotationReason { case daily, size }

    private func rotate(stamp: Date, reason: RotationReason) throws {
        try fileHandle.synchronize()
        try fileHandle.close()

        let rotatedPath = Self.rotatedPath(basePath: basePath, stamp: stamp, reason: reason)
        let fm = FileManager.default

        if fm.fileExists(atPath: rotatedPath) {
            // Collision (rare: two rotations in the same second).
            // Append a monotonic suffix rather than overwriting —
            // an overwrite would destroy audit evidence.
            var counter = 1
            var candidate = rotatedPath
            while fm.fileExists(atPath: candidate) {
                candidate = "\(rotatedPath).\(counter)"
                counter += 1
            }
            try fm.moveItem(atPath: basePath, toPath: candidate)
        } else {
            try fm.moveItem(atPath: basePath, toPath: rotatedPath)
        }

        fm.createFile(atPath: basePath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: basePath) else {
            throw AuditSinkError.recordingFailed(reason: "cannot reopen audit file after rotation: \(basePath)")
        }
        self.fileHandle = handle
        self.bytesWritten = 0
    }

    private static func rotatedPath(basePath: String, stamp: Date, reason: RotationReason) -> String {
        let day = dayString(stamp)
        switch reason {
        case .daily:
            return "\(basePath).\(day).jsonl"
        case .size:
            let time = timeString(stamp)
            return "\(basePath).\(day).\(time).jsonl"
        }
    }

    private static func utcDay(of date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return DateComponents() }
        cal.timeZone = utc
        return cal.dateComponents([.year, .month, .day], from: date)
    }

    private static func dayString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HHmmss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        return fmt.string(from: date)
    }
}
