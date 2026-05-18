import Foundation
import SpooktacularCore

/// Synchronous, lock-guarded denylist of consumed break-glass
/// ticket IDs.
///
/// Implements OWASP JWT Cheat Sheet §"Implement a deny list" for
/// break-glass single-use enforcement. The API is intentionally
/// synchronous so it can be called from the guest agent's
/// non-async `routeRequest` without a cascade of `async`
/// refactors. Correctness comes from a single `NSLock` that
/// serializes every read/modify/write — a concurrent consume of
/// the same JTI becomes the textbook race that the lock turns
/// into one success + N-1 failures.
///
/// ## Scope: per-agent vs fleet-wide
///
/// **Per-agent (``UsedTicketCache``)** — a ticket consumed on
/// one guest agent does NOT prevent the same ticket from being
/// consumed on a different agent in the same fleet. Acceptable
/// when break-glass tickets are scoped to a single agent, which
/// was the original single-host assumption.
///
/// **Fleet-wide (``FleetUsedTicketCache``)** — a ticket
/// consumed on ANY host marks it consumed everywhere. This is
/// the required topology for multi-tenant deployments where a
/// ticket can be presented to any of N controllers or agents:
///
/// - Break-glass tickets are scoped to a single `tenant` at
///   issuance time. A ticket for tenant A can never be replayed
///   against tenant B's agents regardless of the cache topology.
/// - Cross-agent replay within a tenant is the specific threat
///   the fleet-wide cache closes: a ticket minted with `max_uses=1`
///   must truly be used once, not once-per-agent.
///
/// ## Operator responsibility
///
/// Choose per-agent when running single-host OR when every
/// ticket is scoped to exactly one agent in a multi-tenant
/// deployment (rare). Choose fleet-wide in every other case.
/// ``ProductionPreflight`` enforces the multi-tenant
/// requirement at startup.
///
/// ## Memory bound
///
/// Entries are held until their `expiresAt` passes; because
/// tickets have a 1-hour max TTL (enforced by the codec), the
/// cache can never hold more than `issue-rate × 1h` entries. A
/// hard upper cap (`maxEntries`) guards against pathological
/// cases where an attacker mints many valid-signed tickets.
public final class UsedTicketCache: @unchecked Sendable {

    /// Hard upper bound on tracked entries. Reached only under
    /// adversarial conditions (valid signatures + exhausted
    /// policy). Eviction is oldest-first by `expiresAt` — an
    /// attacker who fills the cache only defers their own
    /// replay window, never erases a fresh ticket's record.
    public let maxEntries: Int

    private struct Entry {
        let jti: String
        let expiresAt: Date
        var usedCount: Int
        let maxUses: Int
    }

    private var entries: [String: Entry] = [:]
    // NSLock rather than os_unfair_lock because SpooktacularApplication
    // is Foundation-only by Clean Architecture invariant. The
    // throughput difference is imperceptible at our call rate
    // (single-digit tickets/minute at the absolute worst case).
    private let lock = NSLock()

    public init(maxEntries: Int = 100_000) {
        self.maxEntries = maxEntries
    }

    /// Atomically consumes one use of a ticket's JTI.
    ///
    /// Returns `true` when the ticket had remaining uses and the
    /// use counter was incremented. Returns `false` when the
    /// ticket is already exhausted (including prior expiries
    /// still in the cache).
    public func tryConsume(
        jti: String,
        expiresAt: Date,
        maxUses: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        evictExpiredLocked(budget: 64, now: now)

        if let existing = entries[jti] {
            guard existing.usedCount < existing.maxUses,
                  existing.expiresAt > now else {
                return false
            }
            entries[jti]?.usedCount += 1
            return true
        }

        if entries.count >= maxEntries {
            evictOldestLocked()
        }

        entries[jti] = Entry(
            jti: jti,
            expiresAt: expiresAt,
            usedCount: 1,
            maxUses: maxUses
        )
        return true
    }

    /// Returns the number of tracked entries. Test-only — not
    /// useful in production paths.
    public var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    // MARK: - Eviction (lock-held)

    private func evictExpiredLocked(budget: Int, now: Date) {
        var removed = 0
        for (jti, entry) in entries {
            if removed >= budget { break }
            if entry.expiresAt <= now {
                entries.removeValue(forKey: jti)
                removed += 1
            }
        }
    }

    private func evictOldestLocked() {
        guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else {
            return
        }
        entries.removeValue(forKey: oldest.key)
    }
}

// MARK: - Fleet-wide variant

/// Fleet-wide used-ticket denylist built on a ``FleetSingleton``.
///
/// Delegates the atomicity claim to the backend (DynamoDB
/// conditional write, etc.), which is the only layer that can
/// honour "consumed once globally" across multiple agents or
/// controllers. Unlike ``UsedTicketCache``, this variant is
/// async — callers must be on an async path.
///
/// The `maxUses` knob that the per-agent cache supports is
/// intentionally absent here: a `FleetSingleton` mark is
/// binary (consumed / not), and encoding a multi-use counter
/// would require a read-modify-write that defeats the point of
/// the backend's single-writer guarantee. Operators who need
/// N-use tickets must either mint N distinct JTIs or stick
/// with the per-agent cache.
public actor FleetUsedTicketCache {
    private let singleton: any FleetSingleton

    /// Wraps a ``FleetSingleton`` backend so every ticket
    /// consumption query travels through the shared store's
    /// atomic conditional write. Pass a
    /// ``DynamoDBFleetSingleton`` in production or an
    /// ``InProcessFleetSingleton`` in unit tests.
    public init(singleton: any FleetSingleton) {
        self.singleton = singleton
    }

    /// Atomically consumes a ticket once, fleet-wide.
    ///
    /// - Parameters:
    ///   - jti: Unique ticket identifier.
    ///   - expiresAt: When the ticket naturally expires — the
    ///     backend uses this to set its TTL so expired entries
    ///     auto-evict.
    /// - Returns: `true` on first consume, `false` when another
    ///   host (or this one) already consumed the ticket.
    public func tryConsume(jti: String, expiresAt: Date) async throws -> Bool {
        let now = Date()
        guard expiresAt > now else { return false }
        let ttl = expiresAt.timeIntervalSince(now)
        let outcome = try await singleton.mark(id: "jti:\(jti)", ttl: ttl)
        switch outcome {
        case .freshMark: return true
        case .alreadyConsumed: return false
        }
    }
}
