import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication

@Suite("Multi-Tenant Auth", .tags(.security, .rbac))
struct MultiTenantAuthTests {

    // MARK: - Isolation Policy

    @Suite("Isolation Policy")
    struct IsolationPolicy {

        @Test("single-tenant isolation allows all scheduling, reuse, and break-glass")
        func singleTenantAllowsAll() {
            let isolation = SingleTenantIsolation()
            #expect(isolation.canSchedule(tenant: TenantID("a"), onto: HostPoolID("any")))
            #expect(isolation.canReuse(vm: "v1", fromTenant: TenantID("a"), forTenant: TenantID("b")))
            #expect(isolation.breakGlassAllowed(for: TenantID("a")))
        }

        @Test("multi-tenant isolation blocks cross-tenant VM reuse")
        func multiTenantBlocksCrossReuse() {
            let isolation = MultiTenantIsolation(tenantPools: [
                TenantID("blue"): [HostPoolID("pool-1")],
                TenantID("red"): [HostPoolID("pool-2")],
            ])
            #expect(!isolation.canReuse(vm: "v1", fromTenant: TenantID("blue"), forTenant: TenantID("red")))
            #expect(isolation.canReuse(vm: "v1", fromTenant: TenantID("blue"), forTenant: TenantID("blue")))
        }

        @Test("multi-tenant scheduling respects tenant-to-pool mapping", arguments: [
            ("blue", "pool-1", true),
            ("blue", "pool-2", false),
            ("red", "pool-1", false),
        ] as [(String, String, Bool)])
        func tenantScheduling(tenantID: String, poolID: String, expected: Bool) {
            let isolation = MultiTenantIsolation(tenantPools: [
                TenantID("blue"): [HostPoolID("pool-1")],
            ])
            #expect(isolation.canSchedule(
                tenant: TenantID(tenantID), onto: HostPoolID(poolID)
            ) == expected)
        }

        @Test("multi-tenant isolation disables break-glass by default")
        func multiTenantNoBreakGlass() {
            let isolation = MultiTenantIsolation(tenantPools: [:])
            #expect(!isolation.breakGlassAllowed(for: TenantID("any")))
        }

        @Test("multi-tenant isolation allows break-glass for explicitly opted-in tenants")
        func multiTenantBreakGlassOptIn() {
            let isolation = MultiTenantIsolation(
                tenantPools: [:],
                breakGlassTenants: [TenantID("emergency")]
            )
            #expect(isolation.breakGlassAllowed(for: TenantID("emergency")))
            #expect(!isolation.breakGlassAllowed(for: TenantID("other")))
        }
    }

    // MARK: - Authorization Service

    @Suite("Authorization Service")
    struct AuthorizationServiceTests {

        @Test("single-tenant authorization allows all scopes without role store", .timeLimit(.minutes(1)))
        func singleTenantAllowsAllScopes() async {
            let auth = SingleTenantAuthorization()
            let ctx = AuthorizationContext(
                actorIdentity: "test", tenant: .default, scope: .runner,
                resource: "vm-1", action: "start"
            )
            #expect(await auth.authorize(ctx))
        }

        @Test("single-tenant authorization allows break-glass", .timeLimit(.minutes(1)))
        func singleTenantAllowsBreakGlass() async {
            let auth = SingleTenantAuthorization()
            let ctx = AuthorizationContext(
                actorIdentity: "test", tenant: .default, scope: .breakGlass,
                resource: "vm-1", action: "exec"
            )
            #expect(await auth.authorize(ctx))
        }

        @Test("multi-tenant authorization denies break-glass by default", .timeLimit(.minutes(1)))
        func multiTenantDeniesBreakGlass() async {
            let isolation = MultiTenantIsolation(tenantPools: [:])
            let auth = MultiTenantAuthorization(
                policy: .multiTenant, isolation: isolation, roleStore: EmptyRoleStore()
            )
            let ctx = AuthorizationContext(
                actorIdentity: "test", tenant: TenantID("blue"), scope: .breakGlass,
                resource: "vm-1", action: "exec"
            )
            #expect(!(await auth.authorize(ctx)))
        }

        @Test("multi-tenant authorization denies when actor has no roles", .timeLimit(.minutes(1)))
        func multiTenantDeniesNoRoles() async {
            let isolation = MultiTenantIsolation(tenantPools: [:])
            let auth = MultiTenantAuthorization(
                policy: .multiTenant, isolation: isolation, roleStore: EmptyRoleStore()
            )
            let ctx = AuthorizationContext(
                actorIdentity: "test", tenant: TenantID("blue"), scope: .runner,
                resource: "vm-1", action: "create"
            )
            #expect(!(await auth.authorize(ctx)))
        }

        @Test("multi-tenant authorization permits when role grants permission", .timeLimit(.minutes(1)))
        func multiTenantPermitsWithRole() async {
            let isolation = MultiTenantIsolation(tenantPools: [
                TenantID("blue"): [HostPoolID("pool-1")],
            ])
            let store = InMemoryRoleStore()
            let tenant = TenantID("blue")
            await store.addRole(BuiltInRole.ciOperator(tenant: tenant))
            await store.addAssignment(RoleAssignment(
                actorIdentity: "dev@blue.com", tenant: tenant, role: "ci-operator"
            ))
            let auth = MultiTenantAuthorization(
                policy: .multiTenant, isolation: isolation, roleStore: store
            )
            let ctx = AuthorizationContext(
                actorIdentity: "dev@blue.com", tenant: tenant, scope: .runner,
                resource: "vm", action: "create"
            )
            #expect(await auth.authorize(ctx))
        }
    }

    // MARK: - Reuse Policy

    @Suite("Reuse Policy")
    struct ReusePolicyTests {

        @Test("single-tenant policy allows warm pool, break-glass, and cross-tenant reuse")
        func singleTenantPolicy() {
            let policy = ReusePolicy.singleTenant
            #expect(policy.warmPoolAllowed)
            #expect(policy.breakGlassAllowed)
            #expect(policy.crossTenantReuseAllowed)
        }

        @Test("multi-tenant policy forbids cross-tenant reuse and break-glass")
        func multiTenantPolicy() {
            let policy = ReusePolicy.multiTenant
            #expect(policy.warmPoolAllowed)
            #expect(!policy.breakGlassAllowed)
            #expect(!policy.crossTenantReuseAllowed)
            #expect(policy.ephemeralDefault)
        }

        @Test("default policy matches tenancy mode", arguments: [
            (TenancyMode.singleTenant, true, true),
            (TenancyMode.multiTenant, false, false),
        ] as [(TenancyMode, Bool, Bool)])
        func defaultPolicyMatchesMode(mode: TenancyMode, expectedBreakGlass: Bool, expectedCrossTenant: Bool) {
            let policy = ReusePolicy.default(for: mode)
            #expect(policy.breakGlassAllowed == expectedBreakGlass)
            #expect(policy.crossTenantReuseAllowed == expectedCrossTenant)
        }
    }

    // MARK: - Audit Records

    @Suite("Audit Records")
    struct AuditRecords {

        @Test("audit record from authorization context captures all fields")
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

        @Test("audit record captures resource from context")
        func auditCapturesResource() {
            let ctx = AuthorizationContext(
                actorIdentity: "admin", tenant: .default,
                scope: .admin, resource: "host-01", action: "drain"
            )
            let record = AuditRecord(context: ctx, outcome: .success)
            #expect(record.resource == "host-01")
        }

        @Test("audit outcome values are distinct", arguments: [
            (AuditOutcome.success, "success"),
            (AuditOutcome.denied, "denied"),
            (AuditOutcome.failed, "failed"),
            (AuditOutcome.timeout, "timeout"),
        ] as [(AuditOutcome, String)])
        func outcomeRawValues(outcome: AuditOutcome, rawValue: String) {
            #expect(outcome.rawValue == rawValue)
        }
    }

    // MARK: - AuthScope Ordering

    @Suite("Scope Ordering")
    struct ScopeOrdering {

        @Test("scopes are ordered: read < runner < admin < breakGlass", arguments: [
            (AuthScope.read, AuthScope.runner),
            (AuthScope.runner, AuthScope.admin),
            (AuthScope.admin, AuthScope.breakGlass),
        ] as [(AuthScope, AuthScope)])
        func scopeOrdering(lower: AuthScope, higher: AuthScope) {
            #expect(lower < higher)
        }

        @Test("scope is not less than itself")
        func scopeNotLessThanSelf() {
            #expect(!(AuthScope.runner < AuthScope.runner))
        }
    }
}
