import Foundation

/// Fleet-wide at-most-once claim port.
///
/// ``FleetSingleton`` answers the question: "Has *any* controller in
/// the fleet already marked this identifier?" The per-process
/// `NSLock` caches (nonce replay, break-glass denylist) that were
/// fine for single-host deployments fall over the moment two
/// controllers or two agents share traffic — a nonce consumed on
/// controller A is not visible to controller B, so a replay attack
/// simply hits B on the second attempt.
///
/// The protocol is intentionally narrower than
/// ``DistributedLockService``:
///
/// - No renewal. Marks are fire-and-forget claims that expire by
///   absolute TTL. A replay-protection mark should never "renew" —
///   it either already happened or it hasn't.
/// - No explicit release. Correctness does not depend on releasing
///   a mark; TTL expiry is the one and only exit. This removes the
///   whole class of "release didn't happen because the process
///   crashed" bugs that distributed locks have to design around.
/// - Result is an enum, not a `Bool` with "see the docs for what
///   `true` means". ``MarkOutcome`` pins the semantics at the type
///   level: `.freshMark` (we wrote a new entry) vs
///   `.alreadyConsumed` (someone else got there first).
///
/// ## Typical backends
///
/// - ``DynamoDBFleetSingleton`` — conditional `PutItem` with a TTL
///   attribute. Multi-region via Global Tables. Preferred for
///   Fortune-20 fleets that span regions.
/// - Kubernetes ConfigMap / Secret — single-cluster only, but
///   available with zero cloud dependencies.
/// - A local fallback that degenerates to a single in-memory
///   `NSLock`-guarded dictionary — acceptable ONLY when the
///   operator has declared the deployment single-host.
///
/// ## Contract
///
/// Two callers racing with the same `id` observe exactly one
/// `.freshMark` and one (or more) `.alreadyConsumed`. The
/// implementation MUST uphold this even under network retries,
/// process crashes, and multi-region writes. Implementations that
/// cannot (e.g., eventual-consistency-only stores) are not valid
/// backends.
public protocol FleetSingleton: Sendable {

    /// Atomically claim `id` for `ttl` seconds.
    ///
    /// - Parameters:
    ///   - id: Application-chosen identifier. Nonce UUID for replay
    ///     cache, JTI for break-glass denylist, any string for
    ///     caller-defined uses. The backend treats it opaquely.
    ///   - ttl: How long the claim must survive. After `ttl`
    ///     elapses, the backend MAY evict the entry — callers that
    ///     need longer must choose a longer TTL; the protocol does
    ///     not support extensions.
    /// - Returns: ``MarkOutcome/freshMark`` on the first writer,
    ///   ``MarkOutcome/alreadyConsumed`` on every subsequent
    ///   attempt within the TTL window.
    /// - Throws: On transport / backend error. Callers MUST fail
    ///   closed on a thrown error — "we don't know" is not the
    ///   same as "it's fresh."
    func mark(id: String, ttl: TimeInterval) async throws -> MarkOutcome
}

/// The result of a ``FleetSingleton/mark(id:ttl:)`` call.
public enum MarkOutcome: Sendable, Equatable {

    /// The identifier was not present; this call created it.
    case freshMark

    /// The identifier was already recorded (by this call, another
    /// caller, or a previous attempt within the TTL window).
    case alreadyConsumed
}
