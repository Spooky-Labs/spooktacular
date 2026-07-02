import Foundation
import SpooktacularCore
import SpooktacularApplication

/// Builds a ``DistributedLockService`` implementation from environment
/// configuration.
///
/// ## Selection
///
/// **`FileDistributedLock`** — the only backend. Single-host or
/// shared-NFS deployments; uses `flock(2)` on `SPOOKTACULAR_LOCK_DIR`
/// (defaults to `~/.spooktacular/locks`).
///
/// The factory is pure — no I/O, no network. It only reads
/// environment variables and constructs the adapter.
///
/// ## Example
///
/// ```swift
/// let lock = try DistributedLockFactory.makeFromEnvironment()
/// guard let lease = try await lock.acquire(
///     name: "runner-pool", holder: hostID, duration: 30
/// ) else { throw LockError.contended }
/// ```
public enum DistributedLockFactory {

    /// The selection tier chosen by ``makeFromEnvironment()``.
    ///
    /// Surfaced on return so operators can log the backend actually
    /// in use.
    public enum Backend: Sendable, Equatable, CustomStringConvertible {
        case file(lockDir: String)

        public var description: String {
            switch self {
            case .file(let dir): "File(dir=\(dir))"
            }
        }
    }

    /// A lock adapter paired with the backend tag that produced it.
    public struct Built: Sendable {
        public let lock: any DistributedLockService
        public let backend: Backend
    }

    /// Constructs the lock implementation dictated by the current
    /// process environment.
    public static func makeFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Built {
        let lockDir = environment["SPOOKTACULAR_LOCK_DIR"]
            ?? (NSHomeDirectory() + "/.spooktacular/locks")
        let lock = FileDistributedLock(lockDir: lockDir)
        return Built(lock: lock, backend: .file(lockDir: lockDir))
    }
}
