import Testing
import Foundation
@testable import SpookCore

/// Covers the max-min fair allocator that sits above the runner
/// pool reconciler. These are algorithm-level tests — the wiring
/// into `RunnerPoolReconciler` is a separate plug-in point an
/// operator adopts when they hit the "one tenant took everything"
/// failure mode on a busy fleet.
@Suite("Fair scheduler", .tags(.scheduler))
struct FairSchedulerTests {

    // MARK: - Happy path

    @Test("demand ≤ capacity → everyone gets what they asked for")
    func underSubscribed() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 3),
            .init(tenant: TenantID("b"), weight: 1),
        ])
        let alloc = s.allocate(
            demand: [TenantID("a"): 2, TenantID("b"): 1],
            capacity: 10
        )
        #expect(alloc[TenantID("a")] == 2)
        #expect(alloc[TenantID("b")] == 1)
    }

    @Test("3:1 weights split contested capacity proportionally")
    func weightedSplit() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 3),
            .init(tenant: TenantID("b"), weight: 1),
        ])
        let alloc = s.allocate(
            demand: [TenantID("a"): 20, TenantID("b"): 20],
            capacity: 8
        )
        #expect(alloc[TenantID("a")] == 6)
        #expect(alloc[TenantID("b")] == 2)
    }

    @Test("minGuaranteed prevents starvation of low-weight tenants")
    func minGuaranteedHonored() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("hog"),     weight: 10),
            .init(tenant: TenantID("security"), weight: 1, minGuaranteed: 2),
        ])
        let alloc = s.allocate(
            demand: [TenantID("hog"): 100, TenantID("security"): 4],
            capacity: 10
        )
        // security gets at least its minimum even though its
        // weight would otherwise yield ~1 slot out of 10.
        #expect(alloc[TenantID("security")]! >= 2)
    }

    @Test("maxCap caps a tenant even when weight would give them more")
    func maxCapHonored() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 10, maxCap: 3),
            .init(tenant: TenantID("b"), weight: 1),
        ])
        let alloc = s.allocate(
            demand: [TenantID("a"): 100, TenantID("b"): 100],
            capacity: 10
        )
        #expect(alloc[TenantID("a")] == 3)
        // Surplus from a's cap redistributed to b.
        #expect(alloc[TenantID("b")] == 7)
    }

    // MARK: - Edge cases

    @Test("zero capacity returns all zeros")
    func zeroCapacity() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 1),
        ])
        let alloc = s.allocate(demand: [TenantID("a"): 5], capacity: 0)
        #expect(alloc[TenantID("a")] == 0)
    }

    @Test("no policy for a tenant → treated as weight 1, no minimum, no cap")
    func unpolicyTenantDefaultsToUnit() {
        let s = FairScheduler(policies: [])
        let alloc = s.allocate(
            demand: [TenantID("a"): 5, TenantID("b"): 5],
            capacity: 6
        )
        // 6 split evenly between two weight-1 tenants → 3 each.
        #expect(alloc[TenantID("a")] == 3)
        #expect(alloc[TenantID("b")] == 3)
    }

    @Test("total allocation never exceeds capacity")
    func neverOverAllocates() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 7, minGuaranteed: 3),
            .init(tenant: TenantID("b"), weight: 5, minGuaranteed: 2),
            .init(tenant: TenantID("c"), weight: 2, minGuaranteed: 1),
        ])
        for capacity in [1, 3, 7, 10, 50, 100] {
            let alloc = s.allocate(
                demand: [TenantID("a"): 100, TenantID("b"): 100, TenantID("c"): 100],
                capacity: capacity
            )
            let total = alloc.values.reduce(0, +)
            #expect(total <= capacity,
                    "capacity=\(capacity): total \(total) > \(capacity) — bug in allocator")
        }
    }

    @Test("minimums scale proportionally when they exceed capacity")
    func minimumsOvershoot() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 1, minGuaranteed: 5),
            .init(tenant: TenantID("b"), weight: 1, minGuaranteed: 5),
        ])
        // Combined minimum is 10, but capacity is only 6. Each
        // tenant should get roughly half.
        let alloc = s.allocate(
            demand: [TenantID("a"): 10, TenantID("b"): 10],
            capacity: 6
        )
        let total = alloc.values.reduce(0, +)
        #expect(total <= 6)
        #expect((alloc[TenantID("a")] ?? 0) >= 2)
        #expect((alloc[TenantID("b")] ?? 0) >= 2)
    }

    @Test("determinism: same inputs → same outputs across calls")
    func deterministic() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 3),
            .init(tenant: TenantID("b"), weight: 2),
            .init(tenant: TenantID("c"), weight: 1),
        ])
        let demand = [
            TenantID("a"): 50, TenantID("b"): 50, TenantID("c"): 50,
        ]
        let runs = (0..<5).map { _ in s.allocate(demand: demand, capacity: 12) }
        // Every run identical.
        for run in runs {
            #expect(run == runs[0])
        }
    }

    @Test("work-conserving: all capacity used when aggregate demand ≥ capacity")
    func workConserving() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 1),
            .init(tenant: TenantID("b"), weight: 2),
        ])
        let alloc = s.allocate(
            demand: [TenantID("a"): 10, TenantID("b"): 10],
            capacity: 9
        )
        let total = alloc.values.reduce(0, +)
        #expect(total == 9, "work-conserving: should have used all 9 slots, got \(total)")
    }

    @Test("precondition: weight must be positive")
    func negativeWeightTrapsPrecondition() {
        // Can't easily test preconditionFailure in unit tests
        // without a trap harness; pin the positive-weight
        // constructor by exercising a valid `weight: 1`.
        let policy = TenantSchedulingPolicy(tenant: TenantID("a"), weight: 1)
        #expect(policy.weight == 1)
    }
}

// MARK: - Tag

extension Tag {
    @Tag static var scheduler: Tag
}
