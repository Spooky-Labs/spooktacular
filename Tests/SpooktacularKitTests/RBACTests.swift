import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("RBAC")
struct RBACTests {

    // MARK: - Built-in Roles

    @Test("Viewer has only list permissions")
    func viewerPermissions() {
        let viewer = BuiltInRole.viewer()
        #expect(viewer.allows(resource: "vm", action: "list"))
        #expect(!viewer.allows(resource: "vm", action: "create"))
        #expect(!viewer.allows(resource: "vm", action: "delete"))
    }

    @Test("CI Operator inherits viewer + has create/start/stop")
    func ciOperatorPermissions() {
        let op = BuiltInRole.ciOperator()
        #expect(op.allows(resource: "vm", action: "list"))
        #expect(op.allows(resource: "vm", action: "create"))
        #expect(op.allows(resource: "vm", action: "start"))
        #expect(op.allows(resource: "vm", action: "stop"))
        #expect(!op.allows(resource: "vm", action: "delete"))
    }

    @Test("Platform Admin inherits ci-operator + has delete/drain")
    func platformAdminPermissions() {
        let admin = BuiltInRole.platformAdmin()
        #expect(admin.allows(resource: "vm", action: "list"))
        #expect(admin.allows(resource: "vm", action: "create"))
        #expect(admin.allows(resource: "vm", action: "delete"))
        #expect(admin.allows(resource: "host", action: "drain"))
        #expect(!admin.allows(resource: "audit", action: "export"))
    }

    @Test("Security Admin has audit permissions but not VM delete")
    func securityAdminPermissions() {
        let sec = BuiltInRole.securityAdmin()
        #expect(sec.allows(resource: "audit", action: "export"))
        #expect(sec.allows(resource: "audit", action: "verify"))
        #expect(!sec.allows(resource: "vm", action: "delete"))
    }

    // MARK: - RBAC Authorization

    @Test("RBACAuthorization denies by default (no roles)")
    func denyByDefault() async {
        let store = InMemoryRoleStore()
        let auth = RBACAuthorization(roleStore: store, isolation: SingleTenantIsolation())
        let ctx = AuthorizationContext(
            actorIdentity: "unknown", tenant: .default,
            scope: .runner, resource: "vm", action: "create"
        )
        #expect(!(await auth.authorize(ctx)))
    }

    @Test("RBACAuthorization permits when role matches")
    func permitWhenRoleMatches() async {
        let store = InMemoryRoleStore()
        await store.addRole(BuiltInRole.ciOperator())
        await store.addAssignment(RoleAssignment(
            actorIdentity: "user@example.com", tenant: .default, role: "ci-operator"
        ))
        let auth = RBACAuthorization(roleStore: store, isolation: SingleTenantIsolation())
        let ctx = AuthorizationContext(
            actorIdentity: "user@example.com", tenant: .default,
            scope: .runner, resource: "vm", action: "create"
        )
        #expect(await auth.authorize(ctx))
    }

    @Test("RBACAuthorization denies when role lacks permission")
    func denyWhenRoleLacksPermission() async {
        let store = InMemoryRoleStore()
        await store.addRole(BuiltInRole.viewer())
        await store.addAssignment(RoleAssignment(
            actorIdentity: "viewer@example.com", tenant: .default, role: "viewer"
        ))
        let auth = RBACAuthorization(roleStore: store, isolation: SingleTenantIsolation())
        let ctx = AuthorizationContext(
            actorIdentity: "viewer@example.com", tenant: .default,
            scope: .runner, resource: "vm", action: "delete"
        )
        #expect(!(await auth.authorize(ctx)))
    }

    // MARK: - Role Assignment

    @Test("Expired assignment is detected")
    func assignmentExpiry() {
        let expired = RoleAssignment(
            actorIdentity: "a", tenant: .default, role: "r",
            assignedAt: Date.distantPast, expiresAt: Date.distantPast
        )
        let valid = RoleAssignment(
            actorIdentity: "a", tenant: .default, role: "r",
            assignedAt: Date(), expiresAt: Date.distantFuture
        )
        #expect(expired.isExpired)
        #expect(!valid.isExpired)
    }

    // MARK: - Permission

    @Test("Permission equality and hashing")
    func permissionEquality() {
        let p1 = Permission(resource: "vm", action: "start")
        let p2 = Permission(resource: "vm", action: "start")
        let p3 = Permission(resource: "vm", action: "stop")
        #expect(p1 == p2)
        #expect(p1 != p3)
        #expect(Set([p1, p2]).count == 1)
    }

    // MARK: - IdP Config

    @Test("IdPConfig OIDC round-trip")
    func idpConfigOIDC() throws {
        let config = IdPConfig.oidc(OIDCProviderConfig(
            issuerURL: "https://login.example.com",
            clientID: "app-1"
        ))
        #expect(config.issuer == "https://login.example.com")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(IdPConfig.self, from: data)
        #expect(decoded.issuer == "https://login.example.com")
    }

    @Test("IdPConfig SAML round-trip")
    func idpConfigSAML() throws {
        let config = IdPConfig.saml(SAMLProviderConfig(
            entityID: "https://idp.example.com",
            ssoURL: "https://idp.example.com/sso",
            certificate: "base64cert"
        ))
        #expect(config.issuer == "https://idp.example.com")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(IdPConfig.self, from: data)
        #expect(decoded.issuer == "https://idp.example.com")
    }
}

// MARK: - Test Helpers

