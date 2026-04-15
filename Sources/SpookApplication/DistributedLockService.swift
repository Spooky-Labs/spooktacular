import Foundation
import SpookCore

/// Coordinates exclusive access across multiple hosts.
///
/// Implementations may use Kubernetes Lease objects, a shared
/// database, or etcd. The protocol is intentionally simple:
/// acquire, renew, release.
public protocol DistributedLockService: Sendable {
    /// Attempts to acquire a named lock. Returns the lease if successful, nil if held by another.
    func acquire(name: String, holder: String, duration: TimeInterval) async throws -> DistributedLease?
    /// Renews an existing lease. Fails if the lease was lost.
    func renew(_ lease: DistributedLease, duration: TimeInterval) async throws -> DistributedLease
    /// Releases a lease.
    func release(_ lease: DistributedLease) async throws
}
