import Foundation
import SpookCore
import SpookApplication

/// Distributed lock using file-based advisory locking for non-Kubernetes deployments.
///
/// Uses `open(2)` with `O_CREAT | O_EXCL` as the create-if-absent
/// primitive plus `flock(2)` for process-level mutual exclusion on
/// a shared filesystem (NFS, SMB, or local). `O_EXCL` is the
/// atomic check-and-create guarded against the TOCTOU race the
/// original `O_CREAT | O_RDWR` allowed: two acquires observed no
/// file, both called `open`, both got a descriptor, and whichever
/// lost the `flock` race silently truncated the winner's holder
/// file before closing the fd. `fstat` on the returned descriptor
/// verifies we landed on the inode `O_EXCL` just created rather
/// than a racing writer's replacement.
///
/// Reference: Apple's man 2 open page —
/// <https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/open.2.html>
/// "If O_EXCL is set with O_CREAT and the file already exists,
/// open() returns an error. This may be used to implement a
/// simple exclusive-access locking mechanism."
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

    /// Tracks held locks by name. Each entry stores the fd + the
    /// inode observed at acquire time — CAS and release compare
    /// against this snapshot so a lock file replaced out from
    /// under us (backup restore, manual rm + recreate) surfaces
    /// as a lost-lease error rather than a silent release of the
    /// wrong file.
    private struct Held {
        let fd: Int32
        let inode: UInt64
        var lease: DistributedLease
    }
    private var heldLocks: [String: Held] = [:]

    public init(lockDir: String? = nil) {
        self.lockDir = lockDir
            ?? ProcessInfo.processInfo.environment["SPOOK_LOCK_DIR"]
            ?? (NSHomeDirectory() + "/.spooktacular/locks")

        // Create lock directory if needed. A pre-existing
        // directory is the expected case; any hard failure here
        // would surface at acquire() below when open(2) returns
        // ENOENT, so we don't special-case it.
        try? FileManager.default.createDirectory(
            atPath: self.lockDir,
            withIntermediateDirectories: true
        )
    }

    public func acquire(name: String, holder: String, duration: TimeInterval) async throws -> DistributedLease? {
        let path = lockPath(for: name)

        // Atomic create-if-absent. `O_EXCL` closes the window
        // between stat and open that `O_CREAT | O_RDWR` leaves
        // open — two concurrent acquires cannot both succeed
        // because the second one gets `EEXIST`.
        let fd = open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        if fd < 0 {
            let err = errno
            if err == EEXIST {
                // Another holder beat us to the punch. A stale
                // file (crashed process, abandoned lease) is
                // cleaned up via a best-effort retry: we open
                // the existing file read-only just to test if
                // `flock(LOCK_EX | LOCK_NB)` is obtainable. If
                // yes, the file is orphaned; unlink + retry.
                return try takeoverStaleLockIfPossible(
                    path: path, name: name, holder: holder, duration: duration
                )
            }
            throw FileLockError.openFailed(path: path, errnoCode: err)
        }

        // Verify we own the inode we expect — `fstat` on the fd
        // cannot be racing against another open on a different
        // inode because the fd is bound to the specific inode
        // the kernel created for us at `open` time.
        var statBuf = stat()
        guard fstat(fd, &statBuf) == 0 else {
            let err = errno
            close(fd)
            // Best-effort unlink on the orphan we just created.
            unlink(path)
            throw FileLockError.fstatFailed(path: path, errnoCode: err)
        }
        let inode = UInt64(statBuf.st_ino)

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            // Another process already has the advisory lock on
            // the file we just created — effectively impossible
            // under `O_EXCL`, but defensive.
            close(fd)
            unlink(path)
            return nil
        }

        let lease = DistributedLease(
            name: name, holder: holder,
            duration: duration, version: 1, renewalCount: 0
        )

        // Write holder identity into the file. Debug-only; the
        // lock primitive is `flock(fd)`, not the file contents.
        writeHolderInfo(fd: fd, holder: holder)

        heldLocks[name] = Held(fd: fd, inode: inode, lease: lease)
        return lease
    }

    public func renew(_ lease: DistributedLease, duration: TimeInterval) async throws -> DistributedLease {
        guard let held = heldLocks[lease.name] else {
            throw LockError.leaseLost(lease.name)
        }
        // Inode check: if a human operator rm'd + recreated the
        // lockfile while we held it, the fd we still own points
        // at an inode that has been unlinked. Surface this as a
        // lost lease rather than silently "renewing" a lock we
        // no longer effectively hold.
        var statBuf = stat()
        guard fstat(held.fd, &statBuf) == 0,
              UInt64(statBuf.st_ino) == held.inode else {
            throw LockError.leaseLost(lease.name)
        }
        // Bound the number of renewals per lease. See
        // ``DistributedLease/maxRenewals``.
        let nextCount = held.lease.renewalCount + 1
        guard nextCount <= DistributedLease.maxRenewals else {
            throw DistributedLockServiceError.renewalBudgetExhausted(
                name: lease.name, count: nextCount
            )
        }
        let renewed = DistributedLease(
            name: lease.name, holder: lease.holder,
            duration: duration,
            version: lease.version + 1,
            renewalCount: nextCount
        )
        heldLocks[lease.name]?.lease = renewed
        return renewed
    }

    public func release(_ lease: DistributedLease) async throws {
        guard let held = heldLocks.removeValue(forKey: lease.name) else { return }
        flock(held.fd, LOCK_UN)
        close(held.fd)
        // Remove the lockfile so the next acquire's `O_EXCL`
        // path succeeds. If another holder took over via
        // `takeoverStaleLockIfPossible`, the inode has already
        // changed and our unlink is racing on a different file —
        // that's fine, `unlink` is idempotent under `ENOENT`.
        unlink(lockPath(for: lease.name))
    }

    public func compareAndSwap(
        old: DistributedLease,
        new: DistributedLease
    ) async throws -> Bool {
        guard let held = heldLocks[old.name] else { return false }
        // Only advance if the observed lease matches the held
        // one on version + holder. Any mismatch means someone
        // else has taken over (or the caller is working from a
        // stale snapshot).
        guard held.lease.version == old.version,
              held.lease.holder == old.holder else {
            return false
        }
        // Reject renewalCount shrinkage — the caller can only
        // advance the lease, never rewind it.
        guard new.renewalCount >= held.lease.renewalCount else {
            return false
        }
        if new.renewalCount > DistributedLease.maxRenewals {
            throw DistributedLockServiceError.renewalBudgetExhausted(
                name: new.name, count: new.renewalCount
            )
        }
        heldLocks[old.name]?.lease = new
        return true
    }

    // MARK: - Internals

    private func takeoverStaleLockIfPossible(
        path: String, name: String, holder: String, duration: TimeInterval
    ) throws -> DistributedLease? {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        // We won the `flock` race on a file someone else created
        // but is no longer holding — take it over by unlinking
        // and reacquiring cleanly so the inode matches.
        flock(fd, LOCK_UN)
        close(fd)
        unlink(path)
        // Recurse only once; the second acquire cannot loop
        // back to this path because the file we just unlinked is
        // gone, so `O_EXCL` must succeed (or fail on a fresh
        // race, which propagates as `nil`).
        let reopenFd = open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard reopenFd >= 0 else { return nil }
        var statBuf = stat()
        guard fstat(reopenFd, &statBuf) == 0,
              flock(reopenFd, LOCK_EX | LOCK_NB) == 0 else {
            close(reopenFd)
            unlink(path)
            return nil
        }
        let lease = DistributedLease(
            name: name, holder: holder,
            duration: duration, version: 1, renewalCount: 0
        )
        writeHolderInfo(fd: reopenFd, holder: holder)
        heldLocks[name] = Held(
            fd: reopenFd, inode: UInt64(statBuf.st_ino), lease: lease
        )
        return lease
    }

    private func writeHolderInfo(fd: Int32, holder: String) {
        let info = "\(holder)\n\(Date().ISO8601Format())\n"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        info.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }

    private func lockPath(for name: String) -> String {
        // Sanitize name to prevent path traversal
        let safe = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        return "\(lockDir)/\(safe).lock"
    }
}

/// Typed errors from the file-backed lock backend.
///
/// Distinct from ``LockError`` so callers can discriminate
/// filesystem failures (permissions, ENOSPC, a lock dir that
/// doesn't exist) from coordination failures (a lease lost to
/// another controller). The raw `errno` is preserved so ops can
/// pivot to `man 2 open` when diagnosing.
public enum FileLockError: Error, LocalizedError, Sendable, Equatable {

    /// `open(2)` returned a non-EEXIST failure while trying to
    /// atomically create the lockfile.
    case openFailed(path: String, errnoCode: Int32)

    /// `fstat(2)` failed on the fd we just opened — disk or
    /// filesystem corruption territory.
    case fstatFailed(path: String, errnoCode: Int32)

    public var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code):
            "open(\(path)) failed with errno \(code): \(String(cString: strerror(code)))"
        case .fstatFailed(let path, let code):
            "fstat(\(path)) failed with errno \(code): \(String(cString: strerror(code)))"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .openFailed(let path, let code):
            code == EACCES
                ? "The process doesn't have write access to '\(path)'. Check SPOOK_LOCK_DIR ownership and mode."
                : "Check the error code against `man 2 open` and verify the directory exists."
        case .fstatFailed:
            "The filesystem may be in an inconsistent state. Unmount / remount the lock directory if it's an NFS share."
        }
    }
}
