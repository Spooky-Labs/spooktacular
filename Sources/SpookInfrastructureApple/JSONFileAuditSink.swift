import Foundation
import SpookCore
import SpookApplication

/// Appends audit records as JSON lines to a file.
///
/// Each record is a single JSON object on one line (JSONL format),
/// suitable for ingestion by Splunk, Elasticsearch, CloudWatch Logs,
/// or any SIEM that supports structured JSON log files.
///
/// ## Usage
///
/// ```swift
/// let sink = JSONFileAuditSink(path: "/var/log/spooktacular/audit.jsonl")
/// await sink.record(auditEntry)
/// ```
public actor JSONFileAuditSink: AuditSink {
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder

    /// Creates an audit sink that writes to the given file path.
    /// Creates the file if it doesn't exist.
    public init(path: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            // Create parent directory if needed
            let dir = (path as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw AuditSinkError.cannotOpenFile(path)
        }
        handle.seekToEndOfFile()
        self.fileHandle = handle

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    public func record(_ entry: AuditRecord) async {
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A) // newline
        fileHandle.write(data)
    }
}

/// Errors from audit sink operations.
public enum AuditSinkError: Error, LocalizedError, Sendable {
    case cannotOpenFile(String)

    public var errorDescription: String? {
        switch self {
        case .cannotOpenFile(let path):
            "Cannot open audit file for writing: \(path)"
        }
    }
}
