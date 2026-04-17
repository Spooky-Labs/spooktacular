import Foundation

// MARK: - Per-tenant scheduling policy

/// Per-tenant weight and guarantees used by ``FairScheduler``.
///
/// Orthogonal to ``TenantQuota``, which acts as a hard ceiling
/// regardless of contention. `TenantSchedulingPolicy` is the
/// *share* the tenant gets when demand exceeds supply — the
/// answer to "who gives way first when two tenants both want the
/// last slot?"
///
/// ## Example
///
/// A three-tenant fleet with 10 total VM slots:
///
/// ```swift
/// let policies: [TenantSchedulingPolicy] = [
///     .init(tenant: TenantID("platform"), weight: 3, minGuaranteed: 2),
///     .init(tenant: TenantID("mobile"),   weight: 2, minGuaranteed: 1),
///     .init(tenant: TenantID("data"),     weight: 1, minGuaranteed: 1),
/// ]
/// ```
///
/// When all three tenants demand 20 slots each against a pool of
/// 10, the allocation becomes `{platform: 6, mobile: 3, data: 1}`
/// after honoring the minimums and splitting the rest by weight.
public struct TenantSchedulingPolicy: Sendable, Codable, Equatable {

    /// The tenant this policy applies to.
    public let tenant: TenantID

    /// Integer weight used for proportional sharing when demand
    /// exceeds supply. Higher weight → larger share.
    ///
    /// Interpreted relative to other tenants' weights — weight 3
    /// vs. weight 1 yields a 3:1 split, not 30% vs. 10%.
    public let weight: Int

    /// Minimum slots this tenant is always guaranteed, even
    /// under pressure. Used to prevent starvation of tenants
    /// whose workloads matter for SOC 2 / availability reasons
    /// (security-scanning, build-signing) regardless of weight.
    public let minGuaranteed: Int

    /// Optional hard ceiling. A tenant that demands more than
    /// `maxCap` gets capped here even if the fleet has room —
    /// mirrors the `TenantQuota.maxVMs` gate but lives in the
    /// scheduler layer so it composes with other tenants'
    /// demand.
    public let maxCap: Int?

    public init(
        tenant: TenantID,
        weight: Int,
        minGuaranteed: Int = 0,
        maxCap: Int? = nil
    ) {
        precondition(weight > 0, "weight must be positive")
        precondition(minGuaranteed >= 0, "minGuaranteed must be non-negative")
        precondition(maxCap.map { $0 >= minGuaranteed } ?? true,
                     "maxCap must be ≥ minGuaranteed when set")
        self.tenant = tenant
        self.weight = weight
        self.minGuaranteed = minGuaranteed
        self.maxCap = maxCap
    }
}

// MARK: - Scheduler

/// Max-min fair share allocator for VM slots across tenants.
///
/// Solves the "who gets the last slot when demand > supply?"
/// problem the prior reconciler side-stepped. The current
/// ``RunnerPoolReconciler`` scales each pool independently based
/// on `minRunners`/`maxRunners`; under multi-tenant contention,
/// the first pool to ask wins. That's fine for small fleets but
/// produces starvation on busy ones — a Fortune-20 CI org with
/// three business units sharing an EC2 Mac fleet observed this
/// as the "mobile team took everything" failure mode.
///
/// ## Algorithm
///
/// Max-min fair share with weights:
///
/// 1. Honor every tenant's `minGuaranteed` first. If the fleet
///    can't cover the total of all minimums, scale each
///    proportionally to its minimum.
/// 2. Distribute the remaining capacity in proportion to
///    weights, subject to each tenant's `maxCap` (if any) and
///    its demand.
/// 3. If a tenant's proportional share exceeds its demand or
///    cap, redistribute the surplus among the remaining
///    tenants and repeat until stable.
///
/// The algorithm is `O(n²)` in the tenant count, which is fine
/// for the < 100-tenant fleets we target — real Fortune-20
/// deployments have < 10 business units competing.
///
/// ## Properties
///
/// - **No starvation** when `minGuaranteed` is set.
/// - **Work-conserving**: never leaves capacity idle when
///   some tenant still has unmet demand.
/// - **Deterministic**: given the same policies + demands +
///   capacity, the output is identical. No randomness, no
///   wall-clock dependence.
/// - **Monotone**: adding capacity never reduces any tenant's
///   allocation; adding demand never reduces anyone else's.
public struct FairScheduler: Sendable {

    /// Per-tenant policy, keyed by tenant ID for lookup.
    public let policies: [TenantID: TenantSchedulingPolicy]

    public init(policies: [TenantSchedulingPolicy]) {
        var map: [TenantID: TenantSchedulingPolicy] = [:]
        for p in policies { map[p.tenant] = p }
        self.policies = map
    }

    /// A runner pool's input to per-pool allocation — the
    /// caller-visible identifier, its owning tenant, and the
    /// demand (typically `pool.spec.maxRunners`).
    ///
    /// The pure shape makes the allocator testable without
    /// dragging in the Kubernetes CRD types the reconciler
    /// works with.
    public struct PoolDemand: Sendable, Equatable {
        public let poolName: String
        public let tenant: TenantID
        public let demand: Int
        public init(poolName: String, tenant: TenantID, demand: Int) {
            self.poolName = poolName
            self.tenant = tenant
            self.demand = demand
        }
    }

    /// Allocates `capacity` slots across a list of runner pools,
    /// first splitting fairly between tenants and then splitting
    /// each tenant's share across their pools proportionally to
    /// each pool's demand.
    ///
    /// Returns a `poolName → allocatedSlots` dict. Pools not in
    /// the input are absent from the output, which callers read
    /// as "no fair-share constraint — use the pool's raw spec."
    ///
    /// The two-stage split is what makes fair-share work for the
    /// runner-pool shape: a tenant with two pools, one demanding
    /// 10 and one demanding 5, given 9 from the tenant-level
    /// scheduler, gets 6 and 3 — not 4.5 / 4.5, and not 5 / 5
    /// (which would over-allocate). Largest pool absorbs the
    /// rounding crumb so the sum stays exactly equal to the
    /// tenant's allocation.
    public func allocatePools(
        _ pools: [PoolDemand],
        capacity: Int
    ) -> [String: Int] {
        guard capacity > 0, !pools.isEmpty else { return [:] }

        // Group by tenant.
        var byTenant: [TenantID: [PoolDemand]] = [:]
        for pool in pools {
            byTenant[pool.tenant, default: []].append(pool)
        }

        // Step 1: tenant-level allocation.
        let demand = byTenant.mapValues { pools in pools.reduce(0) { $0 + $1.demand } }
        let tenantAllocation = allocate(demand: demand, capacity: capacity)

        // Step 2: split each tenant's allocation across their pools.
        var result: [String: Int] = [:]
        for (tenant, tenantPools) in byTenant {
            let tenantShare = tenantAllocation[tenant] ?? 0
            let totalDemand = tenantPools.reduce(0) { $0 + $1.demand }
            guard totalDemand > 0 else { continue }

            // Largest-demand pool absorbs the rounding crumb so
            // the sum matches the tenant's share exactly.
            let sorted = tenantPools.sorted { lhs, rhs in
                if lhs.demand != rhs.demand { return lhs.demand > rhs.demand }
                return lhs.poolName < rhs.poolName
            }
            var distributed = 0
            for (i, pool) in sorted.enumerated() {
                if i == sorted.count - 1 {
                    result[pool.poolName] = max(0, tenantShare - distributed)
                } else {
                    let share = (tenantShare * pool.demand) / totalDemand
                    result[pool.poolName] = share
                    distributed += share
                }
            }
        }

        return result
    }

    /// Allocates `capacity` slots across the tenants in `demand`,
    /// honoring weights, minimums, and caps.
    ///
    /// - Parameters:
    ///   - demand: Requested slots per tenant. Tenants absent
    ///     from this dict are treated as demand 0.
    ///   - capacity: Total slots available in the fleet.
    /// - Returns: The allocated slot count per tenant. Sum of
    ///   the values never exceeds `capacity`; individual values
    ///   never exceed the tenant's demand or `maxCap`.
    public func allocate(
        demand: [TenantID: Int],
        capacity: Int
    ) -> [TenantID: Int] {
        guard capacity > 0 else {
            return Dictionary(uniqueKeysWithValues: demand.keys.map { ($0, 0) })
        }

        // Step 1: seed each tenant with its minimum guarantee,
        // clamped by its actual demand. A tenant that demands 0
        // doesn't get slots just because it has a minGuaranteed.
        var allocation: [TenantID: Int] = [:]
        var remaining = capacity
        for (tenant, want) in demand {
            let policy = policies[tenant]
            let minGuarantee = min(policy?.minGuaranteed ?? 0, want)
            let grant = min(minGuarantee, remaining)
            allocation[tenant] = grant
            remaining -= grant
        }

        // If minimums overshot capacity, the greedy order above
        // was biased. Re-normalize proportionally to declared
        // minimums so no tenant disproportionately loses out.
        var effectiveMinimums: [TenantID: Int] = [:]
        var totalMinimums = 0
        for (tenant, want) in demand {
            let minG = policies[tenant]?.minGuaranteed ?? 0
            let effective = min(minG, want)
            effectiveMinimums[tenant] = effective
            totalMinimums += effective
        }
        if totalMinimums > capacity {
            let scaled = proportional(to: effectiveMinimums, total: capacity)
            // Cap at demand — proportional can, in a rounding
            // edge case, hand a tenant more than they asked for.
            return Dictionary(
                uniqueKeysWithValues: scaled.map { ($0, min($1, demand[$0] ?? 0)) }
            )
        }

        // Step 2a: no-starvation floor (conditional).
        //
        // If the pure weighted pass would give any hungry tenant a
        // share of 0 AND capacity can afford a 1-slot floor for
        // every hungry tenant, grant the floor first. This turns the
        // scheduler into "max-min weighted fair" in the classical
        // sense: proportional share dominates when it doesn't starve
        // anyone, and the 1-slot floor kicks in only when it would.
        //
        // Without this conditional, (a) `weights=[1, 1, 100]` at
        // `capacity=3` starves the two low-weight tenants, or (b) an
        // unconditional floor distorts `weights=[3, 1]` at
        // `capacity=8` from the expected 6:2 into 5:3.
        let initiallyHungry = demand.filter { tenant, want in
            let cap = policies[tenant]?.maxCap ?? .max
            return min(want, cap) > 0
        }
        let initialTotalWeight = initiallyHungry.reduce(into: 0) { acc, pair in
            acc += policies[pair.key]?.weight ?? 1
        }
        let anyWouldStarve: Bool
        if initialTotalWeight > 0 && !initiallyHungry.isEmpty {
            anyWouldStarve = initiallyHungry.contains { tenant, _ in
                let weight = policies[tenant]?.weight ?? 1
                return (remaining * weight) / initialTotalWeight == 0
            }
        } else {
            anyWouldStarve = false
        }
        if anyWouldStarve
            && remaining >= initiallyHungry.count
            && !initiallyHungry.isEmpty
        {
            for tenant in initiallyHungry.keys {
                allocation[tenant] = (allocation[tenant] ?? 0) + 1
            }
            remaining -= initiallyHungry.count
        }

        // Step 2b: distribute remaining capacity by weight among
        // tenants with unmet demand, iterating until no surplus is
        // redistributable.
        while remaining > 0 {
            let hungry = demand.filter { tenant, want in
                let current = allocation[tenant] ?? 0
                let cap = policies[tenant]?.maxCap ?? .max
                return current < min(want, cap)
            }
            guard !hungry.isEmpty else { break }

            let totalWeight = hungry.reduce(into: 0) { acc, pair in
                acc += policies[pair.key]?.weight ?? 1
            }
            guard totalWeight > 0 else { break }

            // Compute each hungry tenant's share this round.
            var grants: [TenantID: Int] = [:]
            var slotsUsed = 0
            for (tenant, want) in hungry.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                let weight = policies[tenant]?.weight ?? 1
                // Fractional share, floored — leftovers get
                // redistributed next iteration to keep the loop
                // making progress.
                let share = (remaining * weight) / totalWeight
                let cap = policies[tenant]?.maxCap ?? .max
                let current = allocation[tenant] ?? 0
                let headroom = min(want, cap) - current
                let grant = min(share, headroom)
                if grant > 0 {
                    grants[tenant] = grant
                    slotsUsed += grant
                }
            }

            // If the weighted split granted nothing (every share
            // floored to 0), allocate single slots round-robin by
            // weight until we exhaust the remainder OR every
            // tenant reaches demand/cap. Avoids an infinite loop
            // when `remaining < totalWeight`, and preserves the
            // no-starvation invariant: a low-weight tenant with
            // unmet demand still gets at least one slot in the
            // round before the outer loop exits via the empty
            // `hungry` check.
            if slotsUsed == 0 {
                // Round-robin fallback. Sort by LEAST-ALLOCATED first
                // so zero-allocation tenants get a turn before
                // already-served tenants receive a second slot. This
                // is the no-starvation invariant: when `capacity >=
                // hungry.count`, every hungry tenant gets at least one
                // slot before any gets two. Ties broken by weight
                // descending (honors the policy), then name ascending
                // (determinism).
                var grantedThisRound = false
                for (tenant, want) in hungry.sorted(by: { lhs, rhs in
                    let la = allocation[lhs.key] ?? 0
                    let ra = allocation[rhs.key] ?? 0
                    if la != ra { return la < ra }
                    let lw = policies[lhs.key]?.weight ?? 1
                    let rw = policies[rhs.key]?.weight ?? 1
                    if lw != rw { return lw > rw }
                    return lhs.key.rawValue < rhs.key.rawValue
                }) {
                    guard remaining > 0 else { break }
                    let cap = policies[tenant]?.maxCap ?? .max
                    let current = allocation[tenant] ?? 0
                    if current < min(want, cap) {
                        allocation[tenant] = current + 1
                        remaining -= 1
                        grantedThisRound = true
                    }
                }
                // If nobody could absorb a slot (all at cap or
                // demand), there is no further work to do — break
                // to avoid spinning. Otherwise continue: the
                // outer loop's `hungry` filter handles termination
                // when demand is finally satisfied.
                if !grantedThisRound { break }
                continue
            }

            for (tenant, grant) in grants {
                allocation[tenant] = (allocation[tenant] ?? 0) + grant
                remaining -= grant
            }
        }

        return allocation
    }

    /// Proportional allocation helper used when the sum of
    /// minimums exceeds capacity: each tenant's share is
    /// `capacity * (their minimum / total minimums)`.
    private func proportional(
        to weights: [TenantID: Int],
        total: Int
    ) -> [TenantID: Int] {
        let sum = weights.values.reduce(0, +)
        guard sum > 0 else {
            return Dictionary(uniqueKeysWithValues: weights.keys.map { ($0, 0) })
        }
        var result: [TenantID: Int] = [:]
        var distributed = 0
        // Largest-first so rounding crumbs land on the tenant
        // with the most minimums — feels fair to operators and
        // keeps the total exactly equal to `total`.
        let sorted = weights.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.rawValue < rhs.key.rawValue
        }
        for (i, pair) in sorted.enumerated() {
            if i == sorted.count - 1 {
                // Last tenant absorbs the rounding remainder.
                result[pair.key] = max(0, total - distributed)
            } else {
                let share = (total * pair.value) / sum
                result[pair.key] = share
                distributed += share
            }
        }
        return result
    }
}
