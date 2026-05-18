import Foundation

/// Receives structured audit records and forwards them to durable storage.
///
/// Every control-plane action — create a VM, delete a runner pool, flip
/// tenancy mode — produces exactly one ``AuditRecord`` delivered through
/// this sink. Implementations may write to `os.Logger`, forward to a
/// SIEM, append to a file, publish to S3 Object Lock, or tee into a
/// Merkle tree.
///
/// ## Durability contract
///
/// ``record(_:)`` is `async throws`. Adapters **must** surface write
/// failures as thrown errors; callers **must** propagate those errors
/// up the stack so the control plane can either retry, refuse the
/// operation, or fail open per its audit-loss policy. Swallowing
/// errors at this boundary — with `try?`, `try!`, or a silent
/// `do / catch` that only logs — creates undetectable gaps in the
/// audit trail and is the single most common source of SOC 2 /
/// FedRAMP audit findings in this layer.
///
/// Adapters that tee to multiple destinations (see ``DualAuditSink``)
/// should aggregate partial failures into a single typed error so the
/// caller can distinguish "one sink lost a record" from "every sink
/// failed."
///
/// ## Clean Architecture
///
/// This is a port, not an adapter. It lives in ``SpooktacularCore`` so both
/// use cases and entry points can reference it without importing
/// infrastructure. Concrete adapters
/// (``OSLogAuditSink``, ``JSONFileAuditSink``, ``AppendOnlyFileAuditStore``,
/// ``S3ObjectLockAuditStore``, ``HashChainAuditSink``) live in
/// ``SpooktacularInfrastructureApple``.
public protocol AuditSink: Sendable {

    /// Records a single audit event.
    ///
    /// - Parameter entry: The audit record to persist.
    /// - Throws: ``AuditSinkError`` when the record cannot be durably
    ///   committed. Adapters **must not** swallow errors silently —
    ///   a thrown error signals the caller that the audit trail has
    ///   a gap and the triggering control-plane action should be
    ///   treated as non-repudiable.
    func record(_ entry: AuditRecord) async throws
}

/// Errors raised by ``AuditSink`` adapters when a record cannot be
/// durably recorded.
///
/// Typed so callers can branch on recoverable vs. terminal failures
/// (e.g. retry on ``backendUnavailable``, alert immediately on
/// ``truncatedRead``).
public enum AuditSinkError: Error, Sendable, LocalizedError {
    /// The write was attempted but the backend refused or failed.
    /// `reason` is a human-readable diagnostic safe to include in
    /// operator logs (no credentials, no record contents).
    case recordingFailed(reason: String)

    /// The backend is unreachable or not ready to accept records —
    /// network partition, disk full, daemon not running. Typically
    /// transient; the caller may retry with backoff.
    case backendUnavailable

    /// A read against an append-only store returned fewer bytes than
    /// expected for a known sequence range, indicating corruption
    /// or external truncation. This is a tamper-evidence signal and
    /// must halt verification.
    case truncatedRead

    public var errorDescription: String? {
        switch self {
        case .recordingFailed(let reason): return reason
        case .backendUnavailable: return "audit backend unavailable"
        case .truncatedRead: return "audit store returned truncated read"
        }
    }
}
