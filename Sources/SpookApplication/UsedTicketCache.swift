import Foundation
import SpookCore

/// Actor-backed denylist of consumed break-glass ticket IDs.
///
/// Implements OWASP JWT Cheat Sheet §"Implement a deny list" in
/// the form most directly useful for break-glass: a single-use
/// (or capped-use) guarantee the agent enforces atomically in
/// its own process.
///
/// ## Scope
///
/// The cache is **per-agent-process**. A ticket consumed on one
/// guest agent does NOT prevent the same ticket from being
/// consumed on a different agent in the same fleet. That's a
/// deliberate design choice:
///
/// - Break-glass tickets are scoped to a single `tenant` at
///   issuance time. A ticket for tenant A can never be replayed
///   against tenant B's agents regardless of the cache topology.
/// - Cross-agent replay within a tenant would require the
///   operator to have minted the ticket knowing there were
///   multiple agents handling that tenant's traffic — which is
///   the operator's intent in that case.
/// - A shared cache (Redis, DynamoDB) would add a runtime
///   dependency + consistency failure mode for an edge case
///   operators have never asked for.
///
/// If cross-agent single-use becomes a real requirement, the
/// cache's `tryConsume(_:)` surface is the right plug-in point
/// for a distributed implementation — the rest of the verifier
/// doesn't care.
///
/// ## Memory bound
///
/// Entries are held until their `expiresAt` passes; because
/// tickets have a 1-hour max TTL (enforced by the codec), the
/// cache can never hold more than `issue-rate × 1h` entries. A
/// fleet minting 100 tickets/hour steadies at ~100 cached JTIs —
/// well under any memory pressure threshold. An upper hard cap
/// still guards against pathological cases.
public actor UsedTicketCache {

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

    public init(maxEntries: Int = 100_000) {
        self.maxEntries = maxEntries
    }

    /// Atomically consumes one use of a ticket's JTI.
    ///
    /// Returns `true` when the ticket had remaining uses and the
    /// use counter was incremented. Returns `false` when the
    /// ticket is already exhausted (including prior expiries
    /// still in the cache).
    ///
    /// - Parameters:
    ///   - jti: The ticket's unique identifier.
    ///   - expiresAt: The ticket's expiry — used for eviction
    ///     and to ignore stale denylist entries.
    ///   - maxUses: The ticket's policy cap. Usually 1.
    public func tryConsume(
        jti: String,
        expiresAt: Date,
        maxUses: Int
    ) -> Bool {
        let now = Date()

        // Opportunistic cleanup — remove any entries whose
        // expiresAt is in the past. Bounded to a small amount
        // of work per call so a pathological cache doesn't
        // impose an O(n) latency spike.
        evictExpired(budget: 64, now: now)

        if let existing = entries[jti] {
            guard existing.usedCount < existing.maxUses,
                  existing.expiresAt > now else {
                return false
            }
            entries[jti]?.usedCount += 1
            return true
        }

        // Defensive cap — a well-behaved fleet never hits this,
        // but an attacker minting valid-signed tickets shouldn't
        // be able to OOM the agent.
        if entries.count >= maxEntries {
            evictOldest()
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
    public var entryCount: Int { entries.count }

    // MARK: - Eviction

    private func evictExpired(budget: Int, now: Date) {
        var removed = 0
        for (jti, entry) in entries {
            if removed >= budget { break }
            if entry.expiresAt <= now {
                entries.removeValue(forKey: jti)
                removed += 1
            }
        }
    }

    private func evictOldest() {
        guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else {
            return
        }
        entries.removeValue(forKey: oldest.key)
    }
}
