import Foundation
import SpooktacularCore
import SpooktacularApplication

/// Forwards audit records to two sinks simultaneously.
///
/// Used to write records to both a searchable sink (JSONL/OSLog)
/// and an immutable store (``AppendOnlyFileAuditStore``) in
/// parallel.
///
/// ## Failure semantics
///
/// If either sink throws, ``record(_:)`` throws. When **both**
/// sinks throw, the primary error is wrapped and the secondary's
/// reason is appended to its diagnostic string — otherwise only
/// one of the two failures would be observable and whichever sink
/// ran second would appear healthy.
///
/// Ordering is primary-first so an infrastructure misconfiguration
/// that takes down the primary (e.g. disk full on the JSONL
/// volume) fails loudly before the secondary (e.g. S3 Object Lock)
/// gets a chance to mask the problem by succeeding on its own.
public actor DualAuditSink: AuditSink {
    private let primary: any AuditSink
    private let secondary: any AuditSink

    public init(primary: any AuditSink, secondary: any AuditSink) {
        self.primary = primary
        self.secondary = secondary
    }

    public func record(_ entry: AuditRecord) async throws {
        var primaryError: Error?
        var secondaryError: Error?
        do {
            try await primary.record(entry)
        } catch {
            primaryError = error
        }
        do {
            try await secondary.record(entry)
        } catch {
            secondaryError = error
        }
        switch (primaryError, secondaryError) {
        case (nil, nil):
            return
        case (let p?, nil):
            throw p
        case (nil, let s?):
            throw s
        case (let p?, let s?):
            throw AuditSinkError.recordingFailed(
                reason: "primary: \(p.localizedDescription); secondary: \(s.localizedDescription)"
            )
        }
    }
}
