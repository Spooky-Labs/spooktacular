import Foundation
import SpookCore
import SpookApplication

/// Distributed lock using file-based advisory locking for non-Kubernetes deployments.
///
/// Uses `flock(2)` on a shared filesystem (NFS, SMB, or local) to coordinate
/// across multiple hosts. Each lock creates a file at a well-known path;
/// `flock(LOCK_EX | LOCK_NB)` provides mutual exclusion.
///
/// ## When to use
///
/// - Non-Kubernetes deployments (standalone Mac hosts)
/// - Hosts sharing an NFS mount or network filesystem
/// - Single-host deployments (local coordination)
///
/// For Kubernetes deployments, use `KubernetesLeaseLock` instead.
///
/// ## Configuration
///
/// Set `SPOOK_LOCK_DIR` to a shared directory accessible by all hosts
/// (e.g., an NFS mount). Default: `~/.spooktacular/locks/`
public actor FileDistributedLock: DistributedLockService {
    private let lockDir: String
    private var heldLocks: [String: Int32] = [:]  // name → file descriptor

    public init(lockDir: String? = nil) {
        self.lockDir = lockDir
            ?? ProcessInfo.processInfo.environment["SPOOK_LOCK_DIR"]
            ?? (NSHomeDirectory() + "/.spooktacular/locks")

        // Create lock directory if needed
        try? FileManager.default.createDirectory(
            atPath: self.lockDir,
            withIntermediateDirectories: true
        )
    }

    public func acquire(name: String, holder: String, duration: TimeInterval) async throws -> DistributedLease? {
        let path = lockPath(for: name)

        // Open or create the lock file
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }

        // Try non-blocking exclusive lock
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil  // Lock held by another process
        }

        // Write holder identity to the file for debugging
        let info = "\(holder)\n\(Date().ISO8601Format())\n"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        info.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }

        heldLocks[name] = fd
        return DistributedLease(name: name, holder: holder, duration: duration)
    }

    public func renew(_ lease: DistributedLease, duration: TimeInterval) async throws -> DistributedLease {
        guard heldLocks[lease.name] != nil else {
            throw LockError.leaseLost(lease.name)
        }
        // flock is held until released — no explicit renewal needed
        // Just return a new lease with updated timing
        return DistributedLease(name: lease.name, holder: lease.holder, duration: duration)
    }

    public func release(_ lease: DistributedLease) async throws {
        guard let fd = heldLocks.removeValue(forKey: lease.name) else { return }
        flock(fd, LOCK_UN)
        close(fd)
    }

    private func lockPath(for name: String) -> String {
        // Sanitize name to prevent path traversal
        let safe = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return "\(lockDir)/\(safe).lock"
    }
}
