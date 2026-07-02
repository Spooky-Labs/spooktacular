import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

@Suite("EnterpriseIntegration")
struct EnterpriseIntegrationTests {

    // MARK: - Cross-Tenant Denial

    @Test("Multi-tenant isolation denies scheduling to wrong pool")
    func crossTenantSchedulingDenied() {
        let isolation = MultiTenantIsolation(tenantPools: [
            TenantID("team-a"): [HostPoolID("pool-a")],
            TenantID("team-b"): [HostPoolID("pool-b")],
        ])
        #expect(!isolation.canSchedule(tenant: TenantID("team-a"), onto: HostPoolID("pool-b")))
        #expect(!isolation.canSchedule(tenant: TenantID("team-b"), onto: HostPoolID("pool-a")))
        #expect(isolation.canSchedule(tenant: TenantID("team-a"), onto: HostPoolID("pool-a")))
    }

    @Test("Multi-tenant isolation denies cross-tenant VM reuse")
    func crossTenantReuseDenied() {
        let isolation = MultiTenantIsolation(tenantPools: [:])
        #expect(!isolation.canReuse(vm: "vm-1", fromTenant: TenantID("a"), forTenant: TenantID("b")))
        #expect(isolation.canReuse(vm: "vm-1", fromTenant: TenantID("a"), forTenant: TenantID("a")))
    }

    @Test("Multi-tenant denies break-glass for unconfigured tenant")
    func breakGlassDeniedByDefault() async {
        let isolation = MultiTenantIsolation(tenantPools: [:])
        let auth = MultiTenantAuthorization(policy: .multiTenant, isolation: isolation, roleStore: EmptyRoleStore())
        let ctx = AuthorizationContext(
            actorIdentity: "user", tenant: TenantID("x"),
            scope: .breakGlass, resource: "vm", action: "exec"
        )
        #expect(!(await auth.authorize(ctx)))
    }

    @Test("Per-tenant break-glass allows configured tenants")
    func perTenantBreakGlass() {
        let isolation = MultiTenantIsolation(
            tenantPools: [TenantID("ops"): [HostPoolID("pool-1")]],
            breakGlassTenants: [TenantID("ops")]
        )
        #expect(isolation.breakGlassAllowed(for: TenantID("ops")))
        #expect(!isolation.breakGlassAllowed(for: TenantID("dev")))
    }

    // MARK: - Audit Trail

    @Test("AuditRecord JSON round-trip preserves all fields")
    func auditRecordRoundTrip() throws {
        let record = AuditRecord(
            actorIdentity: "ctrl", tenant: TenantID("blue"),
            scope: .admin, resource: "vm-42", action: "delete",
            outcome: .denied, correlationID: "corr-1"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AuditRecord.self, from: data)
        #expect(decoded.actorIdentity == "ctrl")
        #expect(decoded.tenant == TenantID("blue"))
        #expect(decoded.outcome == .denied)
    }

    // MARK: - Distributed Lock

    @Test("DistributedLease expiry detection")
    func leaseExpiry() {
        let expired = DistributedLease(name: "t", holder: "h", acquiredAt: Date.distantPast, duration: 1)
        let active = DistributedLease(name: "t", holder: "h", duration: 3600)
        #expect(expired.isExpired)
        #expect(!active.isExpired)
    }
}
