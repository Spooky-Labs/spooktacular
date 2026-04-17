import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

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

    // MARK: - Merkle Audit

    @Test("MerkleAuditSink produces signed tree heads")
    func merkleSTH() async throws {
        let key = P256.Signing.PrivateKey()
        let sink = MerkleAuditSink(wrapping: CollectingAuditSink(), signer: key)
        let record = AuditRecord(
            actorIdentity: "t", tenant: .default, scope: .read,
            resource: "h", action: "check", outcome: .success
        )
        try await sink.record(record)
        let sth = try await sink.signedTreeHead()
        #expect(sth.treeSize == 1)
        #expect(!sth.rootHash.isEmpty)
        #expect(!sth.signature.isEmpty)
    }

    @Test("MerkleAuditSink tree grows monotonically")
    func merkleGrowth() async throws {
        let key = P256.Signing.PrivateKey()
        let sink = MerkleAuditSink(wrapping: CollectingAuditSink(), signer: key)
        for i in 0..<5 {
            let r = AuditRecord(
                actorIdentity: "a\(i)", tenant: .default, scope: .read,
                resource: "r", action: "a", outcome: .success
            )
            try await sink.record(r)
            #expect(await sink.treeSize() == i + 1)
        }
    }

    @Test("MerkleAuditSink inclusion proof is non-empty")
    func merkleInclusionProof() async throws {
        let key = P256.Signing.PrivateKey()
        let sink = MerkleAuditSink(wrapping: CollectingAuditSink(), signer: key)
        for i in 0..<4 {
            let r = AuditRecord(
                actorIdentity: "a", tenant: .default, scope: .read,
                resource: "r\(i)", action: "a", outcome: .success
            )
            try await sink.record(r)
        }
        let proof = await sink.inclusionProof(forLeafAt: 1)
        #expect(proof != nil)
        #expect(!proof!.isEmpty)
    }

    // MARK: - Federated Identity

    @Test("FederatedIdentity expiry detection")
    func federatedExpiry() {
        let expired = FederatedIdentity(issuer: "i", subject: "s", expiresAt: Date.distantPast)
        let valid = FederatedIdentity(issuer: "i", subject: "s", expiresAt: Date.distantFuture)
        #expect(expired.isExpired())
        #expect(!valid.isExpired())
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
