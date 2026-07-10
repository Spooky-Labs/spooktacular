import Foundation
import SpooktacularCore

/// Fleet-wide used-ticket denylist built on a ``FleetSingleton``.
///
/// Delegates the atomicity claim to the backend (DynamoDB
/// conditional write, etc.), which is the only layer that can
/// honour "consumed once globally" across multiple agents or
/// controllers. The API is async — callers must be on an async
/// path.
///
/// The `maxUses` knob a per-JTI single-use cache would otherwise
/// support is intentionally absent here: a `FleetSingleton` mark
/// is binary (consumed / not), and encoding a multi-use counter
/// would require a read-modify-write that defeats the point of
/// the backend's single-writer guarantee. Operators who need
/// N-use tickets must mint N distinct JTIs instead.
public actor FleetUsedTicketCache {
    private let singleton: any FleetSingleton

    /// Wraps a ``FleetSingleton`` backend so every ticket
    /// consumption query travels through the shared store's
    /// atomic conditional write. Pass an
    /// `InProcessFleetSingleton`, the only backend Spooktacular
    /// ships.
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
