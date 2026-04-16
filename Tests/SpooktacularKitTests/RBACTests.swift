import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("RBAC", .tags(.security, .rbac))
struct RBACTests {

    // MARK: - Built-in Roles

    @Suite("Built-in Roles")
    struct BuiltInRoles {

        @Test("built-in role grants correct permissions", arguments: [
            ("viewer", "vm", "list", true),
            ("viewer", "pool", "list", true),
            ("viewer", "runner-group", "list", true),
            ("viewer", "host", "list", true),
            ("viewer", "audit", "list", true),
            ("viewer", "vm", "create", false),
            ("viewer", "vm", "delete", false),
            ("ci-operator", "vm", "list", true),
            ("ci-operator", "vm", "create", true),
            ("ci-operator", "vm", "start", true),
            ("ci-operator", "vm", "stop", true),
            ("ci-operator", "pool", "schedule", true),
            ("ci-operator", "vm", "delete", false),
            ("platform-admin", "vm", "list", true),
            ("platform-admin", "vm", "create", true),
            ("platform-admin", "vm", "delete", true),
            ("platform-admin", "host", "drain", true),
            ("platform-admin", "pool", "create", true),
            ("platform-admin", "pool", "delete", true),
            ("platform-admin", "runner-group", "manage", true),
            ("platform-admin", "audit", "export", false),
            ("security-admin", "audit", "export", true),
            ("security-admin", "audit", "verify", true),
            ("security-admin", "host", "rotate-certs", true),
            ("security-admin", "vm", "delete", false),
        ] as [(String, String, String, Bool)])
        func rolePermission(roleID: String, resource: String, action: String, expected: Bool) {
            let role: Role = switch roleID {
            case "viewer": BuiltInRole.viewer()
            case "ci-operator": BuiltInRole.ciOperator()
            case "platform-admin": BuiltInRole.platformAdmin()
            case "security-admin": BuiltInRole.securityAdmin()
            default: fatalError("Unknown role: \(roleID)")
            }
            #expect(role.allows(resource: resource, action: action) == expected)
        }

        @Test("ci-operator inherits all viewer permissions")
        func ciOperatorInheritsViewer() {
            let viewer = BuiltInRole.viewer()
            let ciOp = BuiltInRole.ciOperator()
            #expect(viewer.permissions.isSubset(of: ciOp.permissions))
        }

        @Test("platform-admin inherits all ci-operator permissions")
        func platformAdminInheritsCiOperator() {
            let ciOp = BuiltInRole.ciOperator()
            let admin = BuiltInRole.platformAdmin()
            #expect(ciOp.permissions.isSubset(of: admin.permissions))
        }

        @Test("security-admin inherits viewer but not ci-operator create")
        func securityAdminInheritsViewer() {
            let viewer = BuiltInRole.viewer()
            let secAdmin = BuiltInRole.securityAdmin()
            #expect(viewer.permissions.isSubset(of: secAdmin.permissions))
            #expect(!secAdmin.allows(resource: "vm", action: "create"))
        }
    }

    // MARK: - Authorization

    @Suite("Authorization")
    struct Authorization {

        @Test("denies by default when actor has no roles", .timeLimit(.minutes(1)))
        func denyByDefault() async {
            let store = InMemoryRoleStore()
            let auth = RBACAuthorization(roleStore: store, isolation: SingleTenantIsolation())
            let ctx = AuthorizationContext(
                actorIdentity: "unknown", tenant: .default,
                scope: .runner, resource: "vm", action: "create"
            )
            #expect(!(await auth.authorize(ctx)))
        }

        @Test("permits when assigned role grants the requested permission", .timeLimit(.minutes(1)))
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

        @Test("denies when assigned role lacks the requested permission", .timeLimit(.minutes(1)))
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

        @Test("break-glass delegates to isolation policy", .timeLimit(.minutes(1)))
        func breakGlassDelegatesToIsolation() async {
            let store = InMemoryRoleStore()
            let auth = RBACAuthorization(roleStore: store, isolation: SingleTenantIsolation())
            let ctx = AuthorizationContext(
                actorIdentity: "admin", tenant: .default,
                scope: .breakGlass, resource: "vm", action: "exec"
            )
            // SingleTenantIsolation allows break-glass
            #expect(await auth.authorize(ctx))
        }
    }

    // MARK: - Permissions

    @Suite("Permissions")
    struct Permissions {

        @Test("equal permissions have the same identity")
        func equality() {
            let p1 = Permission(resource: "vm", action: "start")
            let p2 = Permission(resource: "vm", action: "start")
            #expect(p1 == p2)
        }

        @Test("different permissions are not equal")
        func inequality() {
            let p1 = Permission(resource: "vm", action: "start")
            let p2 = Permission(resource: "vm", action: "stop")
            #expect(p1 != p2)
        }

        @Test("set deduplicates identical permissions")
        func hashingDeduplication() {
            let p1 = Permission(resource: "vm", action: "start")
            let p2 = Permission(resource: "vm", action: "start")
            #expect(Set([p1, p2]).count == 1)
        }
    }

    // MARK: - Assignments

    @Suite("Assignments")
    struct Assignments {

        @Test("expired assignment is detected as expired")
        func expiredAssignment() {
            let expired = RoleAssignment(
                actorIdentity: "a", tenant: .default, role: "r",
                assignedAt: Date.distantPast, expiresAt: Date.distantPast
            )
            #expect(expired.isExpired)
        }

        @Test("valid assignment is not expired")
        func validAssignment() {
            let valid = RoleAssignment(
                actorIdentity: "a", tenant: .default, role: "r",
                assignedAt: Date(), expiresAt: Date.distantFuture
            )
            #expect(!valid.isExpired)
        }

        @Test("assignment without expiration is never expired")
        func noExpirationNeverExpires() {
            let noExpiry = RoleAssignment(
                actorIdentity: "a", tenant: .default, role: "r"
            )
            #expect(!noExpiry.isExpired)
        }

        @Test("expired assignment is excluded from role lookup", .timeLimit(.minutes(1)))
        func expiredAssignmentExcludedFromLookup() async throws {
            let store = InMemoryRoleStore()
            await store.addRole(BuiltInRole.ciOperator())
            await store.addAssignment(RoleAssignment(
                actorIdentity: "user@example.com", tenant: .default, role: "ci-operator",
                assignedAt: Date.distantPast, expiresAt: Date.distantPast
            ))
            let roles = try await store.rolesForActor("user@example.com", tenant: .default)
            #expect(roles.isEmpty)
        }
    }

    // MARK: - IdP Config

    @Suite("IdP Configuration")
    struct IdPConfiguration {

        @Test("OIDC config round-trips through JSON")
        func oidcRoundTrip() throws {
            let config = IdPConfig.oidc(OIDCProviderConfig(
                issuerURL: "https://login.example.com",
                clientID: "app-1"
            ))
            #expect(config.issuer == "https://login.example.com")
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(IdPConfig.self, from: data)
            #expect(decoded.issuer == "https://login.example.com")
        }

        @Test("SAML config round-trips through JSON")
        func samlRoundTrip() throws {
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
}
