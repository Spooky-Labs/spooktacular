import Foundation
import SpookCore
import SpookApplication

/// Forwards audit records to two sinks simultaneously.
///
/// Used to write records to both a searchable sink (JSONL/OSLog)
/// and an immutable store (AppendOnlyFileAuditStore) in parallel.
public actor DualAuditSink: AuditSink {
    private let primary: any AuditSink
    private let secondary: any AuditSink

    public init(primary: any AuditSink, secondary: any AuditSink) {
        self.primary = primary
        self.secondary = secondary
    }

    public func record(_ entry: AuditRecord) async {
        await primary.record(entry)
        await secondary.record(entry)
    }
}
