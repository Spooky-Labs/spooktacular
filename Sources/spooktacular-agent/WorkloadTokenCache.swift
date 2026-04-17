import Foundation

/// In-memory cache of the most recent workload-identity token
/// minted by the control plane for this VM.
///
/// ``WorkloadTokenRefresher`` is the companion actor that
/// populates the cache on a timer and mirrors it to the on-disk
/// path declared by `SPOOK_WORKLOAD_TOKEN_FILE` so unmodified
/// AWS / GCP / Azure SDKs pick it up transparently. This cache
/// itself is the in-memory coordination point; reads are
/// lock-protected and cheap.
public final class WorkloadTokenCache: @unchecked Sendable {

    public static let shared = WorkloadTokenCache()

    public struct Snapshot: Sendable {
        public let token: String
        public let roleArn: String
        public let audience: String
        public let expiresAt: Date
    }

    private let lock = NSLock()
    private var current: Snapshot?

    private init() {}

    /// Returns the current snapshot if one exists and is not
    /// expired (with 15 seconds of margin so callers don't race
    /// a hard expiry). Returns `nil` if no token has been
    /// fetched yet or the last one has lapsed.
    public func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let c = current, c.expiresAt > Date().addingTimeInterval(15) else {
            return nil
        }
        return c
    }

    /// Replaces the cached snapshot with `new`.
    public func replace(with new: Snapshot) {
        lock.lock()
        defer { lock.unlock() }
        current = new
    }

    /// Clears the cache. Used at shutdown and on refresh
    /// failure to avoid serving stale tokens.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        current = nil
    }
}
