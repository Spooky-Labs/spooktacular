import Foundation
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

        // Set BSD append-only flag (UF_APPEND).
        // After this, the file can only be appended to — modifications
        // and deletions are blocked at the kernel level.
        // Only root can remove this flag via `chflags nouchg <path>`.
        var sb = Darwin.stat()
        if Darwin.lstat(path, &sb) == 0 {
            chflags(path, sb.st_flags | UInt32(UF_APPEND))
        }
    }

    // AuditSink conformance
    public func record(_ entry: AuditRecord) async {
        _ = try? await append(entry)
    }

    // ImmutableAuditStore conformance
    public func append(_ record: AuditRecord) async throws -> UInt64 {
        let seq = sequenceNumber
        sequenceNumber += 1
        var data = try encoder.encode(record)
        data.append(0x0A)
        fileHandle.write(data)
        return seq
    }

    public func read(from: UInt64, count: Int) async throws -> [AuditRecord] {
        guard let data = FileManager.default.contents(atPath: filePath) else { return [] }
        let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") ?? []
        let start = Int(from)
        let end = min(start + count, lines.count)
        guard start < lines.count else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines[start..<end].compactMap { try? decoder.decode(AuditRecord.self, from: Data($0.utf8)) }
    }

    public func recordCount() async throws -> UInt64 { sequenceNumber }
}

public enum AppendOnlyError: Error, LocalizedError, Sendable {
    case cannotOpenFile(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let p): "Cannot open append-only audit file: \(p)"
        }
    }
}
