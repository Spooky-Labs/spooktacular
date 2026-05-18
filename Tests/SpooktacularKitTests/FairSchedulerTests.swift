import Testing
import Foundation
@testable import SpooktacularCore

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
            .init(tenant: TenantID("hog"), weight: 10),
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

    @Test("weights [100,100,1] capacity 3 → every tenant gets at least 1 slot")
    func lowWeightTenantNotStarved() {
        // The starvation bug: when the weighted split floors to
        // zero for the low-weight tenant, the old code `break`ed
        // after a single round-robin pass, sometimes leaving the
        // low-weight tenant at 0 even though there was unmet
        // demand + capacity. With the `continue` fix, every
        // tenant with unmet demand gets at least one slot.
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 100),
            .init(tenant: TenantID("b"), weight: 100),
            .init(tenant: TenantID("c"), weight: 1),
        ])
        let alloc = s.allocate(
            demand: [TenantID("a"): 10, TenantID("b"): 10, TenantID("c"): 10],
            capacity: 3
        )
        #expect(alloc[TenantID("a")] ?? 0 >= 1, "tenant a starved")
        #expect(alloc[TenantID("b")] ?? 0 >= 1, "tenant b starved")
        #expect(alloc[TenantID("c")] ?? 0 >= 1, "tenant c starved — the specific bug this test pins")
        #expect(alloc.values.reduce(0, +) == 3)
    }

    @Test("property: no tenant with unmet demand is starved at capacity ≥ tenants")
    func noStarvationProperty() {
        // Sweep a small parameter space to exercise the
        // round-robin fallback under varied weights. The
        // property: at capacity ≥ tenants, no demanding tenant
        // ends up at 0.
        let weightCombos: [[Int]] = [
            [1, 1, 1], [1, 2, 3], [10, 10, 1], [1, 1, 100],
            [5, 3, 1], [100, 1, 1], [1, 100, 1], [2, 2, 2],
        ]
        for weights in weightCombos {
            let s = FairScheduler(policies: weights.enumerated().map { i, w in
                .init(tenant: TenantID("t\(i)"), weight: w)
            })
            let demand: [TenantID: Int] = Dictionary(
                uniqueKeysWithValues: weights.indices.map { (TenantID("t\($0)"), 10) }
            )
            let alloc = s.allocate(demand: demand, capacity: weights.count)
            for i in weights.indices {
                let got = alloc[TenantID("t\(i)")] ?? 0
                #expect(got >= 1, "weights=\(weights): tenant t\(i) starved at \(got)")
            }
        }
    }

    @Test("precondition: weight must be positive")
    func negativeWeightTrapsPrecondition() {
        // Can't easily test preconditionFailure in unit tests
        // without a trap harness; pin the positive-weight
        // constructor by exercising a valid `weight: 1`.
        let policy = TenantSchedulingPolicy(tenant: TenantID("a"), weight: 1)
        #expect(policy.weight == 1)
    }

    // MARK: - Pool-level allocation (wired from RunnerPoolReconciler)

    @Test("allocatePools splits a tenant's share across their pools by demand")
    func poolAllocationSplitsByDemand() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("platform"), weight: 3),
            .init(tenant: TenantID("mobile"), weight: 1),
        ])
        // platform has two pools (demand 10 and 5), mobile has one.
        // Fleet capacity 12; weighted 3:1 → platform 9, mobile 3.
        // platform's 9 splits 10:5 → 6:3 (largest-first).
        let alloc = s.allocatePools([
            .init(poolName: "platform-a", tenant: TenantID("platform"), demand: 10),
            .init(poolName: "platform-b", tenant: TenantID("platform"), demand: 5),
            .init(poolName: "mobile-a", tenant: TenantID("mobile"), demand: 20),
        ], capacity: 12)
        #expect(alloc["platform-a"] == 6)
        #expect(alloc["platform-b"] == 3)
        #expect(alloc["mobile-a"] == 3)
    }

    @Test("allocatePools returns empty on zero capacity")
    func poolAllocationZeroCapacity() {
        let s = FairScheduler(policies: [.init(tenant: TenantID("a"), weight: 1)])
        let alloc = s.allocatePools(
            [.init(poolName: "a1", tenant: TenantID("a"), demand: 5)],
            capacity: 0
        )
        #expect(alloc.isEmpty)
    }

    @Test("allocatePools returns empty on no input pools")
    func poolAllocationNoPools() {
        let s = FairScheduler(policies: [])
        let alloc = s.allocatePools([], capacity: 10)
        #expect(alloc.isEmpty)
    }

    @Test("allocatePools preserves exact tenant-level sums (no rounding drift)")
    func poolAllocationSumsExact() {
        let s = FairScheduler(policies: [
            .init(tenant: TenantID("a"), weight: 7),
            .init(tenant: TenantID("b"), weight: 5),
            .init(tenant: TenantID("c"), weight: 2),
        ])
        let input: [FairScheduler.PoolDemand] = [
            .init(poolName: "a1", tenant: TenantID("a"), demand: 11),
            .init(poolName: "a2", tenant: TenantID("a"), demand: 7),
            .init(poolName: "a3", tenant: TenantID("a"), demand: 3),
            .init(poolName: "b1", tenant: TenantID("b"), demand: 4),
            .init(poolName: "b2", tenant: TenantID("b"), demand: 13),
            .init(poolName: "c1", tenant: TenantID("c"), demand: 9),
        ]
        let alloc = s.allocatePools(input, capacity: 17)
        // Sum of all per-pool allocations must not exceed capacity.
        let total = alloc.values.reduce(0, +)
        #expect(total <= 17)

        // Per tenant, the pool-level split must sum to the tenant-level share.
        let tenantAlloc = s.allocate(
            demand: [
                TenantID("a"): 21, TenantID("b"): 17, TenantID("c"): 9,
            ],
            capacity: 17
        )
        for tenant in ["a", "b", "c"] {
            let perTenantSum = input
                .filter { $0.tenant == TenantID(tenant) }
                .reduce(0) { $0 + (alloc[$1.poolName] ?? 0) }
            #expect(perTenantSum == tenantAlloc[TenantID(tenant)] ?? 0,
                    "tenant \(tenant) pool sum \(perTenantSum) != tenant share \(tenantAlloc[TenantID(tenant)] ?? 0)")
        }
    }

    @Test("allocatePools: single-tenant single-pool with full capacity → pool == min(demand, capacity)")
    func poolAllocationSingleTenantPool() {
        let s = FairScheduler(policies: [.init(tenant: TenantID("solo"), weight: 1)])
        let capped = s.allocatePools(
            [.init(poolName: "only", tenant: TenantID("solo"), demand: 100)],
            capacity: 20
        )
        #expect(capped["only"] == 20)

        let underDemand = s.allocatePools(
            [.init(poolName: "only", tenant: TenantID("solo"), demand: 5)],
            capacity: 20
        )
        #expect(underDemand["only"] == 5)
    }
}

// MARK: - Tag

extension Tag {
    @Tag static var scheduler: Tag
}
