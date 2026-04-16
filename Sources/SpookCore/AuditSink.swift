import Foundation

/// Receives structured audit records and forwards them to durable storage.
///
/// Every control-plane action — create a VM, delete a runner pool, flip
/// tenancy mode — produces exactly one ``AuditRecord`` delivered through
/// this sink. Implementations may write to `os.Logger`, forward to a
/// SIEM, append to a file, publish to S3 Object Lock, or tee into a
/// Merkle tree.
///
/// ## Clean Architecture
///
/// This is a port, not an adapter. It lives in ``SpookCore`` so both
/// use cases and entry points can reference it without importing
/// infrastructure. Concrete adapters
/// (``OSLogAuditSink``, ``JSONFileAuditSink``, ``AppendOnlyFileAuditStore``,
/// ``S3ObjectLockAuditStore``, ``HashChainAuditSink``) live in
/// ``SpookInfrastructureApple``.
public protocol AuditSink: Sendable {

    /// Records a single audit event.
    ///
    /// Adapters must not swallow errors silently — write failures should
    /// be surfaced through the adapter's own logging so that gaps in the
    /// audit trail are visible to operators.
    func record(_ entry: AuditRecord) async
}
