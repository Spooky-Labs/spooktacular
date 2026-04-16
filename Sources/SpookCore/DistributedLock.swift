import Foundation

/// A time-bounded exclusive claim on a named resource.
///
/// `DistributedLease` is the value type returned by distributed-lock
/// implementations (``KubernetesLeaseLock`` in cluster deployments,
/// ``FileDistributedLock`` for single-host). It carries the claim
/// (`holder`), its lifetime (`acquiredAt` / `expiresAt`), and a
/// `version` for optimistic concurrency — callers renewing or
/// releasing a lease MUST pass the version they observed, and the
/// implementation bumps it on every write.
///
/// ## Lifecycle
///
/// 1. Caller invokes the lock's `acquire(name:holder:duration:)`.
/// 2. Implementation compares-and-swaps against the prior record's
///    version, writing a new `DistributedLease` with `version + 1`.
/// 3. Caller must periodically `renew(...)` before ``isExpired`` ticks
///    true; otherwise another holder may take over.
/// 4. Caller calls `release(...)` to drop the lease explicitly, or
///    simply stops renewing and lets it expire.
public struct DistributedLease: Sendable, Codable, Equatable {

    /// Resource name this lease gates (e.g., `"capacity-check-host-01"`).
    public let name: String

    /// Identity of the current holder (e.g., `"controller-abc-pod-0"`).
    public let holder: String

    /// Wall-clock time the lease was acquired or last renewed.
    public let acquiredAt: Date

    /// Wall-clock time the lease becomes invalid; the holder must
    /// renew before this to retain the claim.
    public let expiresAt: Date

    /// Monotonically increasing version used for optimistic
    /// concurrency: writers compare-and-swap on this before acquire,
    /// renew, or release, and bump it on every successful write.
    public let version: Int

    public init(
        name: String,
        holder: String,
        acquiredAt: Date = Date(),
        duration: TimeInterval = 15,
        version: Int = 0
    ) {
        self.name = name
        self.holder = holder
        self.acquiredAt = acquiredAt
        self.expiresAt = acquiredAt.addingTimeInterval(duration)
        self.version = version
    }

    /// True when the current wall-clock time is past ``expiresAt``.
    /// Callers should renew before this flips to avoid losing the claim.
    public var isExpired: Bool { Date() > expiresAt }
}
