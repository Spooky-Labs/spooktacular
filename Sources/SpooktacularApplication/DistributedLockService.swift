import Foundation
import SpooktacularCore

/// Coordinates exclusive access across multiple hosts.
///
/// Implementations may use Kubernetes Lease objects, a shared
/// database, or etcd. The protocol is intentionally compact:
/// acquire, renew, release, plus a typed `compareAndSwap(...)`
/// that makes optimistic concurrency the *only* lease-advance
/// path. This closes the "we bump the version in a comment" hole
/// the original API had — the compiler now requires the caller
/// to present both the observed and the intended leases.
///
/// ## Renewal bound
///
/// Implementations MUST refuse to renew a lease whose
/// ``DistributedLease/renewalCount`` is already at
/// ``DistributedLease/maxRenewals``. A lease that has been
/// renewed 100 times in a row is a stuck controller masquerading
/// as a healthy one — prefer to drop the claim and let another
/// controller acquire than to keep extending indefinitely.
public protocol DistributedLockService: Sendable {
    /// Attempts to acquire a named lock. Returns the lease if successful, nil if held by another.
    func acquire(name: String, holder: String, duration: TimeInterval) async throws -> DistributedLease?

    /// Renews an existing lease. Fails if the lease was lost,
    /// or if renewing would exceed
    /// ``DistributedLease/maxRenewals``.
    func renew(_ lease: DistributedLease, duration: TimeInterval) async throws -> DistributedLease

    /// Releases a lease.
    func release(_ lease: DistributedLease) async throws

    /// Advances a lease from `old` to `new` iff the persisted
    /// record still matches `old` on version + holder. Returns
    /// `true` on a successful swap, `false` when a concurrent
    /// writer won the race (the caller's `old` is stale).
    ///
    /// This is the single type-checked path for writers to
    /// advance a lease. `renew` and `release` delegate to this
    /// internally so the CAS invariant is not re-implemented at
    /// each call site. A default implementation would be wrong:
    /// every backend has a different natural CAS primitive
    /// (Kubernetes `resourceVersion`, DynamoDB
    /// `ConditionExpression`, file `fstat` inode), so the
    /// protocol leaves the implementation to the adapter.
    func compareAndSwap(
        old: DistributedLease,
        new: DistributedLease
    ) async throws -> Bool
}

/// Errors raised by ``DistributedLockService`` conformers when the
/// service-level invariants (renewal bound, CAS staleness) are
/// violated. Backend-specific transport errors remain the
/// adapter's own type.
public enum DistributedLockServiceError: Error, LocalizedError, Sendable, Equatable {

    /// A `renew(...)` or `compareAndSwap(...)` would push
    /// ``DistributedLease/renewalCount`` past
    /// ``DistributedLease/maxRenewals``. Caller must drop the
    /// lease and reacquire from scratch.
    case renewalBudgetExhausted(name: String, count: Int)

    public var errorDescription: String? {
        switch self {
        case .renewalBudgetExhausted(let name, let count):
            "Lease '\(name)' has been renewed \(count) times; refusing further renewals. Another controller should take over."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .renewalBudgetExhausted:
            "Release the lease and let another controller acquire it. A controller that has renewed 100 times is almost certainly wedged — investigate the pause before reacquiring."
        }
    }
}
