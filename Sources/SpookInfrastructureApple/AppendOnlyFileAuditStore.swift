import Foundation
import os
import SpookCore
import SpookApplication

/// Append-only file store using macOS BSD file flags for SOC 2 compliance.
///
/// Uses `chflags(UF_APPEND)` to make the audit file append-only at
/// the filesystem level. Once set, records can be appended but never
/// modified or deleted — only root can remove the flag.
///
/// ## SOC 2 Type II
///
/// Combined with `MerkleAuditSink`, this provides both tamper-evidence
/// (Merkle tree + signed tree heads) and immutability (append-only file).
///
/// ## Configuration
///
/// ```bash
/// SPOOK_AUDIT_IMMUTABLE=1
/// SPOOK_AUDIT_IMMUTABLE_PATH=/var/log/spooktacular/audit-immutable.jsonl
/// ```
public actor AppendOnlyFileAuditStore: ImmutableAuditStore, AuditSink {
    private let fileHandle: FileHandle
    private let filePath: String
    private let encoder: JSONEncoder
    private var sequenceNumber: UInt64 = 0
    private let logger = Log.audit

    /// `true` once `chflags(UF_APPEND)` was confirmed applied during
    /// init. Exposed through ``isKernelAppendOnly`` so operators can
    /// include the property in a readiness probe.
    public let isKernelAppendOnly: Bool

    public init(path: String) throws {
        self.filePath = path
        let fm = FileManager.default

        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty && !fm.fileExists(atPath: dir) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }

        // Count existing lines to resume sequence numbering
        if let data = fm.contents(atPath: path),
           let content = String(data: data, encoding: .utf8) {
            sequenceNumber = UInt64(content.split(separator: "\n").count)
        }

        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw AppendOnlyError.cannotOpenFile(path)
        }
        handle.seekToEndOfFile()
        self.fileHandle = handle

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc

        // Set BSD append-only flag (UF_APPEND) and **verify** it
        // stuck. Previously the result of `chflags` was discarded,
        // so the store could advertise kernel-level append-only
        // while running without it — a silent downgrade.
        //
        // After this, the file can only be appended to; modifications
        // and deletions are blocked at the kernel level. Only root
        // can remove this flag via `chflags nouchg <path>`.
        var sb = Darwin.stat()
        var applied = false
        if Darwin.lstat(path, &sb) == 0 {
            let rc = chflags(path, sb.st_flags | UInt32(UF_APPEND))
            if rc == 0 {
                // Re-stat to confirm the flag is present — chflags
                // can return 0 on some filesystems that silently drop
                // the request (APFS network mounts, certain ACLs).
                var verify = Darwin.stat()
                if Darwin.lstat(path, &verify) == 0,
                   verify.st_flags & UInt32(UF_APPEND) != 0 {
                    applied = true
                }
            }
        }
        self.isKernelAppendOnly = applied
        if !applied {
            throw AppendOnlyError.kernelFlagFailed(path)
        }
    }

    // AuditSink conformance — failures propagate. The previous
    // implementation logged-and-returned, which silently converted
    // a disk full / UF_APPEND violation / EIO into "record dropped"
    // and broke the AU-9 non-repudiation contract.
    public func record(_ entry: AuditRecord) async throws {
        do {
            _ = try await append(entry)
        } catch let error as AuditSinkError {
            throw error
        } catch {
            throw AuditSinkError.recordingFailed(reason: "append failed: \(error.localizedDescription)")
        }
    }

    // ImmutableAuditStore conformance.
    //
    // Every record is fsync'd before sequenceNumber advances. A
    // successful return from `append` means the bytes are on
    // durable storage — NIST SP 800-53 AU-9 (protection of audit
    // information) requires this at the adapter boundary, because
    // a controller crash between `write` and `fsync` on a default
    // APFS volume can lose the last writes. `FileHandle.synchronize()`
    // issues fsync(2) under the hood.
    public func append(_ record: AuditRecord) async throws -> UInt64 {
        let seq = sequenceNumber
        var data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw AuditSinkError.recordingFailed(reason: "encode failed: \(error.localizedDescription)")
        }
        data.append(0x0A)
        do {
            try fileHandle.write(contentsOf: data)
            try fileHandle.synchronize()
        } catch {
            throw AuditSinkError.recordingFailed(reason: "fsync write failed: \(error.localizedDescription)")
        }
        // Sequence number advances only after the write commits —
        // if the write throws, callers can retry safely without
        // leaving a hole in the sequence.
        sequenceNumber += 1
        return seq
    }

    /// Reads records at the given sequence range.
    ///
    /// - Throws: ``AuditSinkError/truncatedRead`` if the file is
    ///   shorter than the requested range (external truncation —
    ///   a tamper signal).
    public func read(from: UInt64, count: Int) async throws -> [AuditRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: URL(filePath: filePath))
        } catch {
            throw AuditSinkError.recordingFailed(reason: "read failed: \(error.localizedDescription)")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw AuditSinkError.recordingFailed(reason: "audit file not valid UTF-8")
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        let start = Int(from)
        let end = min(start + count, lines.count)
        guard start < lines.count else { return [] }
        if UInt64(lines.count) < sequenceNumber {
            throw AuditSinkError.truncatedRead
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [AuditRecord] = []
        out.reserveCapacity(end - start)
        for line in lines[start..<end] {
            do {
                out.append(try decoder.decode(AuditRecord.self, from: Data(line.utf8)))
            } catch {
                throw AuditSinkError.recordingFailed(reason: "decode failed: \(error.localizedDescription)")
            }
        }
        return out
    }

    public func recordCount() async throws -> UInt64 { sequenceNumber }
}

public enum AppendOnlyError: Error, LocalizedError, Sendable {
    case cannotOpenFile(String)
    case kernelFlagFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let p):
            "Cannot open append-only audit file: \(p)"
        case .kernelFlagFailed(let p):
            "Could not set UF_APPEND on \(p). The filesystem or ACLs may not support BSD file flags — choose a different audit path or disable SPOOK_AUDIT_IMMUTABLE."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cannotOpenFile(let p):
            "Verify the parent directory exists and the daemon user can write to it: `ls -ld \(URL(filePath: p).deletingLastPathComponent().path)`. Create it with `mkdir -p` + `chown` if missing."
        case .kernelFlagFailed:
            "Move SPOOK_AUDIT_IMMUTABLE_PATH to an APFS volume — UF_APPEND requires BSD file flags. SMB/NFS/external-disk paths often silently reject `chflags`."
        }
    }
}
