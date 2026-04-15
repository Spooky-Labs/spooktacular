import Foundation

/// A lease-based distributed lock for coordinating across multiple hosts.
public struct DistributedLease: Sendable, Codable {
    /// Unique lock name (e.g., "capacity-check-host-01")
    public let name: String
    /// Who holds the lock
    public let holder: String
    /// When the lease was acquired
    public let acquiredAt: Date
    /// When the lease expires (holder must renew before this)
    public let expiresAt: Date
    /// Monotonically increasing version for optimistic concurrency
    public let version: Int

    public init(name: String, holder: String, acquiredAt: Date = Date(),
                duration: TimeInterval = 15, version: Int = 0) {
        self.name = name
        self.holder = holder
        self.acquiredAt = acquiredAt
        self.expiresAt = acquiredAt.addingTimeInterval(duration)
        self.version = version
    }

    public var isExpired: Bool { Date() > expiresAt }
}
