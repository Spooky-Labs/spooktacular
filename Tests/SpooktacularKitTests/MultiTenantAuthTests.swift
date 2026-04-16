import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication

@Suite("MultiTenantAuth")
struct MultiTenantAuthTests {

    // MARK: - TenantIsolationPolicy

    @Test("SingleTenantIsolation allows everything")
    func singleTenantAllowsAll() {
        let isolation = SingleTenantIsolation()
        #expect(isolation.canSchedule(tenant: TenantID("a"), onto: HostPoolID("any")))
        #expect(isolation.canReuse(vm: "v1", fromTenant: TenantID("a"), forTenant: TenantID("b")))
        #expect(isolation.breakGlassAllowed(for: TenantID("a")))
    }

    @Test("MultiTenantIsolation blocks cross-tenant reuse")
    func multiTenantBlocksCrossReuse() {
        let isolation = MultiTenantIsolation(tenantPools: [
            TenantID("blue"): [HostPoolID("pool-1")],
            TenantID("red"): [HostPoolID("pool-2")],
        ])
        #expect(!isolation.canReuse(vm: "v1", fromTenant: TenantID("blue"), forTenant: TenantID("red")))
        #expect(isolation.canReuse(vm: "v1", fromTenant: TenantID("blue"), forTenant: TenantID("blue")))
    }

    @Test("MultiTenantIsolation blocks scheduling to wrong pool")
    func multiTenantBlocksWrongPool() {
        let isolation = MultiTenantIsolation(tenantPools: [
            TenantID("blue"): [HostPoolID("pool-1")],
        ])
        #expect(isolation.canSchedule(tenant: TenantID("blue"), onto: HostPoolID("pool-1")))
        #expect(!isolation.canSchedule(tenant: TenantID("blue"), onto: HostPoolID("pool-2")))
        #expect(!isolation.canSchedule(tenant: TenantID("red"), onto: HostPoolID("pool-1")))
    }

    @Test("MultiTenantIsolation disables break-glass by default")
    func multiTenantNoBreakGlass() {
        let isolation = MultiTenantIsolation(tenantPools: [:])
        #expect(!isolation.breakGlassAllowed(for: TenantID("any")))
    }

    // MARK: - AuthorizationService

    @Test("SingleTenantAuthorization allows all scopes")
    func singleTenantAllowsAllScopes() async {
        let auth = SingleTenantAuthorization()
        let ctx = AuthorizationContext(
            actorIdentity: "test", tenant: .default, scope: .runner,
            resource: "vm-1", action: "start"
        )
        let result = await auth.authorize(ctx)
        #expect(result)
    }

    @Test("SingleTenantAuthorization allows break-glass")
    func singleTenantAllowsBreakGlass() async {
        let auth = SingleTenantAuthorization()
        let ctx = AuthorizationContext(
            actorIdentity: "test", tenant: .default, scope: .breakGlass,
            resource: "vm-1", action: "exec"
        )
        let result = await auth.authorize(ctx)
        #expect(result)
    }

    @Test("MultiTenantAuthorization denies break-glass by default")
    func multiTenantDeniesBreakGlass() async {
        let isolation = MultiTenantIsolation(tenantPools: [:])
        let auth = MultiTenantAuthorization(policy: .multiTenant, isolation: isolation, roleStore: EmptyRoleStore())
        let ctx = AuthorizationContext(
            actorIdentity: "test", tenant: TenantID("blue"), scope: .breakGlass,
            resource: "vm-1", action: "exec"
        )
        let result = await auth.authorize(ctx)
        #expect(!result)
    }

    // MARK: - ReusePolicy

    @Test("SingleTenant policy allows warm pool and break-glass")
    func singleTenantPolicy() {
        let policy = ReusePolicy.singleTenant
        #expect(policy.warmPoolAllowed)
        #expect(policy.breakGlassAllowed)
        #expect(policy.crossTenantReuseAllowed)
    }

    @Test("MultiTenant policy forbids cross-tenant reuse and break-glass")
    func multiTenantPolicy() {
        let policy = ReusePolicy.multiTenant
        #expect(policy.warmPoolAllowed)
        #expect(!policy.breakGlassAllowed)
        #expect(!policy.crossTenantReuseAllowed)
        #expect(policy.ephemeralDefault)
    }

    // MARK: - AuditRecord

    @Test("AuditRecord from AuthorizationContext captures all fields")
    func auditFromContext() {
        let ctx = AuthorizationContext(
            actorIdentity: "controller-1", tenant: TenantID("blue"),
            scope: .runner, resource: "vm-001", action: "deleteVM",
            requestID: "req-42"
        )
        let record = AuditRecord(context: ctx, outcome: .denied)
        #expect(record.actorIdentity == "controller-1")
        #expect(record.tenant == TenantID("blue"))
        #expect(record.scope == .runner)
        #expect(record.action == "deleteVM")
        #expect(record.outcome == .denied)
        #expect(record.correlationID == "req-42")
    }

    // MARK: - AuthScope ordering

    @Test("AuthScope is ordered: read < runner < admin < breakGlass")
    func scopeOrdering() {
        #expect(AuthScope.read < AuthScope.runner)
        #expect(AuthScope.runner < AuthScope.admin)
        #expect(AuthScope.admin < AuthScope.breakGlass)
    }
}

/// A role store that returns no roles (deny-by-default).
