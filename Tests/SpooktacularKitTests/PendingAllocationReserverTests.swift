import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication

/// Tests for the reserver actor that serializes the read-check-
/// write window around tenant-quota admission.
@Suite("Pending allocation reserver", .tags(.security, .lifecycle))
struct PendingAllocationReserverTests {

    @Test("fresh reserver reports pending=0 for every tenant")
    func startsAtZero() async {
        let r = PendingAllocationReserver()
        let count = await r.pending(for: TenantID("a"))
        #expect(count == 0)
    }

    @Test("reserve → pending increments; release → decrements")
    func reserveThenRelease() async throws {
        let r = PendingAllocationReserver()
        let first = try await r.reserve(for: TenantID("a"))
        let afterReserve = await r.pending(for: TenantID("a"))
        #expect(afterReserve == 1)
        await r.release(first)
        let afterRelease = await r.pending(for: TenantID("a"))
        #expect(afterRelease == 0)
    }

    @Test("commit is semantically equivalent to release")
    func commitDecrementsToo() async throws {
        let r = PendingAllocationReserver()
        let res = try await r.reserve(for: TenantID("a"))
        #expect(await r.pending(for: TenantID("a")) == 1)
        await r.commit(res)
        #expect(await r.pending(for: TenantID("a")) == 0)
    }

    @Test("tenants are counted independently")
    func independentTenants() async throws {
        let r = PendingAllocationReserver()
        _ = try await r.reserve(for: TenantID("a"))
        _ = try await r.reserve(for: TenantID("a"))
        _ = try await r.reserve(for: TenantID("b"))
        #expect(await r.pending(for: TenantID("a")) == 2)
        #expect(await r.pending(for: TenantID("b")) == 1)
    }

    @Test("quota evaluation with pending count surfaces in-flight races")
    func quotaWithPending() async throws {
        let r = PendingAllocationReserver()
        let quota = TenantQuota(maxVMs: 2, maxCPUCores: 16, maxMemoryGB: 32)
        let usage = TenantUsage(activeVMs: 1)

        // First caller reserves a slot; the second caller's
        // quota check must reflect the reservation.
        let first = try await r.reserve(for: TenantID("a"))
        let pending = await r.pending(for: TenantID("a"))
        let decision = quota.evaluate(
            usage: usage, request: ResourceRequest(), pending: pending
        )
        #expect(!decision.isAllowed, "second concurrent allocation must see the pending reservation and be denied")

        // Release the reservation (simulated rollback): the next
        // call succeeds again.
        await r.release(first)
        let pending2 = await r.pending(for: TenantID("a"))
        let decision2 = quota.evaluate(
            usage: usage, request: ResourceRequest(), pending: pending2
        )
        #expect(decision2.isAllowed, "after release, the slot is available again")
    }

    @Test("double-release is idempotent")
    func doubleReleaseIsSafe() async throws {
        let r = PendingAllocationReserver()
        let res = try await r.reserve(for: TenantID("a"))
        await r.release(res)
        await r.release(res) // must not underflow
        #expect(await r.pending(for: TenantID("a")) == 0)
    }
}
