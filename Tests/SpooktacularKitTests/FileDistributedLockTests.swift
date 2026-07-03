import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// Tests the O_CREAT | O_EXCL + fstat-inode path of
/// ``FileDistributedLock``, the CAS semantics, and the
/// renewal-budget bound.
@Suite("File distributed lock", .tags(.infrastructure))
struct FileDistributedLockTests {

    private static func tempDir() -> String {
        let dir = NSTemporaryDirectory() + "spooktacular-filelock-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true
        )
        return dir
    }

    @Test("fresh acquire succeeds and returns a lease with renewalCount 0")
    func freshAcquire() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        let lease = try await lock.acquire(
            name: "resource-a", holder: "host-1", duration: 30
        )
        #expect(lease != nil)
        #expect(lease?.renewalCount == 0)
    }

    @Test("second acquire within the same process sees the file + fails cleanly")
    func secondAcquireInSameActorFails() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        let first = try await lock.acquire(
            name: "dupe", holder: "host-1", duration: 30
        )
        #expect(first != nil)
        // `FileDistributedLock` is an actor; a second acquire
        // inside the same actor for a different holder-name
        // would need the old file to go away or be stale. With
        // the same actor holding the descriptor, the EEXIST
        // path + stale takeover returns nil until we release.
        let second = try await lock.acquire(
            name: "dupe", holder: "host-2", duration: 30
        )
        #expect(second == nil)
    }

    @Test("release allows a subsequent acquire on the same name")
    func releaseAllowsReAcquire() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        guard let lease = try await lock.acquire(
            name: "reacq", holder: "host-1", duration: 30
        ) else {
            Issue.record("initial acquire failed")
            return
        }
        try await lock.release(lease)
        let reacquired = try await lock.acquire(
            name: "reacq", holder: "host-2", duration: 30
        )
        #expect(reacquired != nil)
        #expect(reacquired?.holder == "host-2")
    }

    @Test("renew bumps renewalCount and preserves holder")
    func renewIncrementsCount() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        guard let first = try await lock.acquire(
            name: "r", holder: "host-1", duration: 30
        ) else {
            Issue.record("acquire failed"); return
        }
        let renewed = try await lock.renew(first, duration: 30)
        #expect(renewed.renewalCount == 1)
        #expect(renewed.holder == "host-1")
        let renewed2 = try await lock.renew(renewed, duration: 30)
        #expect(renewed2.renewalCount == 2)
    }

    @Test("renew fails after maxRenewals with a typed error")
    func renewalBudgetExhausts() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        guard let first = try await lock.acquire(
            name: "budget", holder: "host-1", duration: 30
        ) else {
            Issue.record("acquire failed"); return
        }
        // Construct a lease sitting at the renewal ceiling and
        // ensure the next renew throws. We bypass the natural
        // renewal loop (100 calls is slow) by swapping in a
        // lease near the boundary via compareAndSwap.
        let almost = DistributedLease(
            name: first.name, holder: first.holder,
            duration: 30, version: first.version + 1,
            renewalCount: DistributedLease.maxRenewals
        )
        let swapped = try await lock.compareAndSwap(old: first, new: almost)
        #expect(swapped, "CAS swap to the near-boundary lease must succeed")
        await #expect(throws: DistributedLockServiceError.self) {
            _ = try await lock.renew(almost, duration: 30)
        }
    }

    @Test("CAS rejects a stale `old` lease")
    func casRejectsStaleOld() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        guard let lease = try await lock.acquire(
            name: "cas", holder: "host-1", duration: 30
        ) else {
            Issue.record("acquire failed"); return
        }
        let staleOld = DistributedLease(
            name: lease.name, holder: lease.holder,
            duration: 30, version: lease.version - 1,
            renewalCount: 0
        )
        let new = DistributedLease(
            name: lease.name, holder: lease.holder,
            duration: 30, version: lease.version + 1,
            renewalCount: 1
        )
        let ok = try await lock.compareAndSwap(old: staleOld, new: new)
        #expect(!ok, "stale `old` lease must not advance")
    }

    @Test("CAS rejects a lease that would exceed maxRenewals")
    func casRejectsOverBudget() async throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = FileDistributedLock(lockDir: dir)
        guard let lease = try await lock.acquire(
            name: "cas-budget", holder: "host-1", duration: 30
        ) else {
            Issue.record("acquire failed"); return
        }
        let overBudget = DistributedLease(
            name: lease.name, holder: lease.holder,
            duration: 30, version: lease.version + 1,
            renewalCount: DistributedLease.maxRenewals + 1
        )
        await #expect(throws: DistributedLockServiceError.self) {
            _ = try await lock.compareAndSwap(old: lease, new: overBudget)
        }
    }
}
