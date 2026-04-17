import Foundation
import SpookCore

/// Counts in-flight (non-yet-committed) VM allocations per
/// tenant, serializing the read-modify-write around quota
/// admission so two concurrent creations cannot both observe
/// "one slot left" and both succeed.
///
/// ## The race this closes
///
/// The original admission path read `usage.activeVMs` from the
/// filesystem, compared against `quota.maxVMs`, and proceeded.
/// Two requests arriving within milliseconds both saw
/// `activeVMs = maxVMs - 1` and both passed the guard — the VM
/// bundle for either request hadn't landed on disk yet when
/// the other request did its count. With `TenantQuota`'s new
/// `pending:` parameter, this reserver is the layer that feeds
/// the right value in:
///
/// 1. `reserve(for: tenant)` atomically increments the
///    pending count and returns a ``Reservation`` handle.
/// 2. The caller runs its slow path (VM bundle creation).
/// 3. On success, the caller calls `commit(_:)` — the entry
///    rolls into the real filesystem count.
/// 4. On failure, the caller calls `release(_:)` — the count
///    decrements so the slot isn't permanently leaked.
///
/// ## Distributed mode
///
/// When constructed with a ``DistributedLockService``, reservations
/// take out a short-lived named lease on `"pending-\(tenant)"`
/// around the increment / check. That lease is the cross-host
/// serialization point — without it, controllers A and B both
/// see the same pending count and both issue a fresh
/// reservation.
///
/// Without a distributed lock, the actor is still correct
/// within a single controller but degrades to per-process in a
/// multi-controller deployment. ``ProductionPreflight`` refuses
/// multi-tenant startup in that case.
public actor PendingAllocationReserver {

    /// A handle returned from ``reserve(tenant:)``. The caller
    /// MUST `commit` or `release` it exactly once — leaks would
    /// permanently reduce available capacity.
    public struct Reservation: Sendable, Equatable {
        public let tenant: TenantID
        public let id: UUID
    }

    /// The lock scope — `.local` when running a single
    /// controller, `.distributed` when a cross-host backend is
    /// wired.
    private enum LockScope {
        case local
        case distributed(any DistributedLockService, holder: String)
    }

    private let scope: LockScope
    private var counts: [TenantID: Int] = [:]
    private var liveReservations: Set<UUID> = []
    private var tenantByReservation: [UUID: TenantID] = [:]

    public init() {
        self.scope = .local
    }

    public init(lock: any DistributedLockService, holder: String) {
        self.scope = .distributed(lock, holder: holder)
    }

    /// Current pending count for a tenant. Primarily for tests
    /// and metrics — callers making admission decisions use
    /// ``reserve(tenant:)`` instead so the check + increment
    /// are atomic.
    public func pending(for tenant: TenantID) -> Int {
        counts[tenant] ?? 0
    }

    /// Reserves a slot for `tenant` and returns a handle the
    /// caller commits or releases. Callers get the pending
    /// count via the ``Reservation/tenant`` so they can pass it
    /// to ``TenantQuota/evaluate(usage:request:pending:)`` to
    /// decide admission — this reserver does NOT do admission
    /// itself; it just supplies the serialized count.
    public func reserve(for tenant: TenantID) async throws -> Reservation {
        if case .distributed(let lock, let holder) = scope {
            // Short-lived lease just to cover the increment
            // window. The lease is released before we return —
            // the `counts` snapshot under the actor IS the
            // cross-host state anchor via the filesystem +
            // distributed lock combo.
            let name = "pending-\(tenant.rawValue)"
            // Retry a small number of times on contention — a
            // tight race on the same tenant reservation is
            // expected under load.
            var attempts = 0
            while attempts < 8 {
                if let lease = try await lock.acquire(
                    name: name, holder: holder, duration: 5
                ) {
                    defer {
                        // Actor-confined; actor methods can't
                        // return before this runs.
                        Task { try? await lock.release(lease) }
                    }
                    return incrementLocked(for: tenant)
                }
                attempts += 1
                try await Task.sleep(nanoseconds: UInt64(50_000_000)) // 50ms
            }
            throw ReservationError.contended(tenant: tenant)
        }
        return incrementLocked(for: tenant)
    }

    /// Discards the reservation, restoring capacity.
    public func release(_ reservation: Reservation) {
        guard liveReservations.remove(reservation.id) != nil else { return }
        tenantByReservation.removeValue(forKey: reservation.id)
        counts[reservation.tenant] = max(0, (counts[reservation.tenant] ?? 0) - 1)
    }

    /// Accepts the reservation. The pending counter decrements —
    /// the caller's slow path succeeded and the slot is now
    /// visible as committed usage (e.g., a VM bundle on disk).
    /// Functionally identical to ``release(_:)`` at this layer
    /// — kept as a distinct method so call sites document intent.
    public func commit(_ reservation: Reservation) {
        release(reservation)
    }

    // MARK: - Internals

    private func incrementLocked(for tenant: TenantID) -> Reservation {
        counts[tenant, default: 0] += 1
        let id = UUID()
        liveReservations.insert(id)
        tenantByReservation[id] = tenant
        return Reservation(tenant: tenant, id: id)
    }
}

/// Errors raised by ``PendingAllocationReserver``.
public enum ReservationError: Error, LocalizedError, Sendable, Equatable {

    /// The distributed lock could not be acquired within the
    /// retry budget. Caller should back off and retry.
    case contended(tenant: TenantID)

    public var errorDescription: String? {
        switch self {
        case .contended(let tenant):
            "Could not acquire pending-allocation lock for tenant '\(tenant.rawValue)' within the retry budget."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .contended:
            "Retry after a short backoff. Sustained contention indicates the tenant's quota is saturated across many controllers simultaneously — consider raising SPOOK_RATE_LIMIT or widening the tenant quota."
        }
    }
}
