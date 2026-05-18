import Foundation

/// A time-bounded exclusive claim on a named resource.
///
/// `DistributedLease` is the value type returned by distributed-lock
/// implementations (``KubernetesLeaseLock`` in cluster deployments,
/// ``FileDistributedLock`` for single-host). It carries the claim
/// (`holder`), its lifetime (`acquiredAt` / `expiresAt`), a
/// `version` for optimistic concurrency, and a `renewalCount`
/// that bounds how many times a single claim can be extended
/// before the lock service refuses further renewals.
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
///
/// ## Renewal bound
///
/// `renewalCount` is incremented on every successful renew. A
/// lease that renews more than ``DistributedLease/maxRenewals``
/// times must be rejected by the backing service — a controller
/// that holds the same lease for hours on end is either a bug or
/// a liveness failure, and either way we want the lock to fall
/// through to another controller rather than silently extending.
public struct DistributedLease: Sendable, Codable, Equatable {

    /// The hard upper bound on lease renewals. Reaching this
    /// count forces release: a controller that has not handed
    /// off in 100 renewal cycles is almost certainly wedged.
    public static let maxRenewals: Int = 100

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

    /// Number of times this lease has been renewed since the
    /// original acquire. Starts at `0` on a fresh acquire and is
    /// incremented by `DistributedLockService.renew(...)`
    /// implementations. A renew that would push this past
    /// ``DistributedLease/maxRenewals`` must throw rather than
    /// silently continue.
    public let renewalCount: Int

    public init(
        name: String,
        holder: String,
        acquiredAt: Date = Date(),
        duration: TimeInterval = 15,
        version: Int = 0,
        renewalCount: Int = 0
    ) {
        self.name = name
        self.holder = holder
        self.acquiredAt = acquiredAt
        self.expiresAt = acquiredAt.addingTimeInterval(duration)
        self.version = version
        self.renewalCount = renewalCount
    }

    /// True when the current wall-clock time is past ``expiresAt``.
    /// Callers should renew before this flips to avoid losing the claim.
    public var isExpired: Bool { Date() > expiresAt }
}
