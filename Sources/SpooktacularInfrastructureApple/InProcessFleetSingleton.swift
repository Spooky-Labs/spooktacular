import Foundation
import SpooktacularCore
import SpooktacularApplication

/// Local in-process ``FleetSingleton`` for single-host
/// deployments. Guarded by a single actor so the
/// read-modify-write is trivially atomic within one process.
/// Explicitly unsafe across processes — the factory / preflight
/// should refuse this backend when tenancy is multi-tenant.
public actor InProcessFleetSingleton: FleetSingleton {

    private struct Entry {
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 100_000) {
        self.maxEntries = maxEntries
    }

    public func mark(id: String, ttl: TimeInterval) async throws -> MarkOutcome {
        let now = Date()
        pruneExpiredLocked(now: now)
        if let existing = entries[id], existing.expiresAt > now {
            return .alreadyConsumed
        }
        if entries.count >= maxEntries {
            evictOldestLocked()
        }
        entries[id] = Entry(expiresAt: now.addingTimeInterval(ttl))
        return .freshMark
    }

    private func pruneExpiredLocked(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func evictOldestLocked() {
        guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else {
            return
        }
        entries.removeValue(forKey: oldest.key)
    }
}
