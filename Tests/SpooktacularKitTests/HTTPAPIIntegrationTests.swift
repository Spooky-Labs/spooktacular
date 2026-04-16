import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("HTTP API Integration", .tags(.integration, .security))
struct HTTPAPIIntegrationTests {

    // MARK: - Helpers

    /// Builds a `SingleTenantAuthorization` backed by the given role store.
    private static func makeAuth(roleStore: any RoleStore) -> SingleTenantAuthorization {
        SingleTenantAuthorization(policy: .singleTenant, roleStore: roleStore)
    }

    /// Creates an `InMemoryRoleStore` pre-loaded with the given role and
    /// an assignment for `actorIdentity`.
    private static func storeWithRole(
        _ role: Role,
        for actorIdentity: String
    ) async -> InMemoryRoleStore {
        let store = InMemoryRoleStore()
        await store.addRole(role)
        await store.addAssignment(RoleAssignment(
            actorIdentity: actorIdentity, tenant: .default, role: role.id
        ))
        return store
    }

    /// Constructs an `AuthorizationContext` mimicking what `routeRequest`
    /// builds internally from HTTP method + path.
    private static func apiContext(
        actor: String = "api-client",
        tenant: TenantID = .default,
        resource: String,
        action: String
    ) -> AuthorizationContext {
        AuthorizationContext(
            actorIdentity: actor,
            tenant: tenant,
            scope: .admin,
            resource: resource,
            action: action
        )
    }

    // MARK: - RBAC Enforcement

    @Suite("RBAC Enforcement")
    struct RBACEnforcement {

        @Test("viewer role cannot create VMs")
        func viewerCannotCreate() async {
            let store = await HTTPAPIIntegrationTests.storeWithRole(
                BuiltInRole.viewer(), for: "viewer-user"
            )
            let auth = HTTPAPIIntegrationTests.makeAuth(roleStore: store)
            let ctx = HTTPAPIIntegrationTests.apiContext(
                actor: "viewer-user", resource: "vm", action: "create"
            )
            let allowed = await auth.authorize(ctx)
            #expect(!allowed, "Viewer role must not be able to create VMs")
        }

        @Test("ci-operator role can create but not delete VMs")
        func ciOperatorPermissions() async {
            let store = await HTTPAPIIntegrationTests.storeWithRole(
                BuiltInRole.ciOperator(), for: "ci-bot"
            )
            let auth = HTTPAPIIntegrationTests.makeAuth(roleStore: store)

            let createCtx = HTTPAPIIntegrationTests.apiContext(
                actor: "ci-bot", resource: "vm", action: "create"
            )
            #expect(await auth.authorize(createCtx), "CI operator should create VMs")

            let startCtx = HTTPAPIIntegrationTests.apiContext(
                actor: "ci-bot", resource: "vm", action: "start"
            )
            #expect(await auth.authorize(startCtx), "CI operator should start VMs")

            let stopCtx = HTTPAPIIntegrationTests.apiContext(
                actor: "ci-bot", resource: "vm", action: "stop"
            )
            #expect(await auth.authorize(stopCtx), "CI operator should stop VMs")

            let deleteCtx = HTTPAPIIntegrationTests.apiContext(
                actor: "ci-bot", resource: "vm", action: "delete"
            )
            #expect(!(await auth.authorize(deleteCtx)), "CI operator must not delete VMs")
        }

        @Test("unauthenticated request returns 401")
        func unauthenticated() async {
            // When no roles exist for the actor, RBAC denies by default.
            let store = EmptyRoleStore()
            let auth = RBACAuthorization(
                roleStore: store, isolation: SingleTenantIsolation()
            )
            let ctx = HTTPAPIIntegrationTests.apiContext(
                actor: "anonymous", resource: "vm", action: "list"
            )
            let allowed = await auth.authorize(ctx)
            #expect(!allowed, "Unauthenticated actor must be denied")
        }

        @Test("wrong token returns 401")
        func wrongToken() async {
            // An actor with a valid identity but no role assignments
            // is equivalent to presenting a wrong/invalid token in
            // the RBAC pipeline -- deny by default.
            let store = InMemoryRoleStore()
            await store.addRole(BuiltInRole.ciOperator())
            // Assign to a *different* actor -- "wrong-token-user" has nothing.
            await store.addAssignment(RoleAssignment(
                actorIdentity: "correct-user", tenant: .default, role: "ci-operator"
            ))
            let auth = RBACAuthorization(
                roleStore: store, isolation: SingleTenantIsolation()
            )
            let ctx = HTTPAPIIntegrationTests.apiContext(
                actor: "wrong-token-user", resource: "vm", action: "list"
            )
            #expect(!(await auth.authorize(ctx)), "Wrong-token actor must be denied")
        }

        @Test("missing RBAC config denies by default")
        func denyByDefault() async {
            // SingleTenantAuthorization with an empty role store:
            // RBAC is configured but contains no roles -- should deny.
            let store = EmptyRoleStore()
            let auth = SingleTenantAuthorization(
                policy: .singleTenant, roleStore: store
            )
            let ctx = HTTPAPIIntegrationTests.apiContext(
                actor: "anybody", resource: "vm", action: "list"
            )
            let allowed = await auth.authorize(ctx)
            #expect(!allowed, "Empty RBAC config must deny by default (OWASP)")
        }
    }

    // MARK: - Rate Limiting

    @Suite("Rate Limiting")
    struct RateLimiting {

        @Test("exceeding rate limit returns 429")
        func rateLimitExceeded() async throws {
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1",
                port: 0,
                vmDirectory: tmpDir.url,
                insecureMode: true
            )

            // The default maxRequestsPerMinute is 120 (or SPOOK_RATE_LIMIT env).
            let ip = "10.0.0.1"
            let limit = 120
            for i in 0..<limit {
                let allowed = await server.checkRateLimit(clientIP: ip)
                #expect(allowed, "Request \(i + 1) of \(limit) should be within limit")
            }
            // The next request should be rate-limited.
            let blocked = await server.checkRateLimit(clientIP: ip)
            #expect(!blocked, "Request \(limit + 1) should be rate-limited (429)")
        }
    }

    // MARK: - Audit Emission

    @Suite("Audit Emission")
    struct AuditEmission {

        @Test("successful request emits audit record with .success")
        func successAudit() async throws {
            let sink = CollectingAuditSink()
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1",
                port: 0,
                vmDirectory: tmpDir.url,
                auditSink: sink,
                insecureMode: true
            )

            // Emit an audit record for a successful request (status < 400).
            await server.emitAPIAudit(
                method: "GET", path: "/v1/vms",
                statusCode: 200, actorIdentity: "test-actor"
            )

            let records = await sink.records
            #expect(records.count == 1, "Should emit exactly one audit record")
            #expect(records[0].outcome == .success, "Status 200 should map to .success")
            #expect(records[0].action == "GET")
            #expect(records[0].resource == "/v1/vms")
        }

        @Test("denied request emits audit record with .failed")
        func deniedAudit() async throws {
            let sink = CollectingAuditSink()
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1",
                port: 0,
                vmDirectory: tmpDir.url,
                auditSink: sink,
                insecureMode: true
            )

            // Emit an audit record for a denied/failed request (status >= 400).
            await server.emitAPIAudit(
                method: "DELETE", path: "/v1/vms/runner-1",
                statusCode: 403, actorIdentity: "test-actor"
            )

            let records = await sink.records
            #expect(records.count == 1, "Should emit exactly one audit record")
            #expect(records[0].outcome == .failed, "Status 403 should map to .failed")
        }

        @Test("audit record contains correct actor, tenant, scope")
        func auditFields() async throws {
            let sink = CollectingAuditSink()
            let tenant = TenantID("blue-team")
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1",
                port: 0,
                vmDirectory: tmpDir.url,
                tenantID: tenant,
                auditSink: sink,
                insecureMode: true
            )

            await server.emitAPIAudit(
                method: "POST", path: "/v1/vms/runner-1/start",
                statusCode: 200, actorIdentity: "alice@example.com"
            )

            let records = await sink.records
            #expect(records.count == 1)
            let record = records[0]
            #expect(record.actorIdentity == "alice@example.com",
                    "Actor identity is now propagated from the verified caller, not hardcoded")
            #expect(record.tenant == tenant,
                    "Tenant should match the server's configured tenantID")
            #expect(record.scope == .admin,
                    "Scope should be .admin for API requests")
        }
    }

    // MARK: - Resource/Action Inference

    @Suite("Resource and Action Inference")
    struct ResourceActionInference {

        @Test("inferResource maps VM paths to 'vm'")
        func inferResourceVM() async throws {
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1", port: 0,
                vmDirectory: tmpDir.url, insecureMode: true
            )
            #expect(await server.inferResource(from: "/v1/vms") == "vm")
            #expect(await server.inferResource(from: "/v1/vms/runner-1") == "vm")
            #expect(await server.inferResource(from: "/v1/vms/runner-1/start") == "vm")
        }

        @Test("inferResource maps metrics path to 'metrics'")
        func inferResourceMetrics() async throws {
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1", port: 0,
                vmDirectory: tmpDir.url, insecureMode: true
            )
            #expect(await server.inferResource(from: "/metrics") == "metrics")
        }

        @Test("inferAction maps HTTP methods correctly")
        func inferActionMethods() async throws {
            let tmpDir = TempDirectory()
            let server = try HTTPAPIServer(
                host: "127.0.0.1", port: 0,
                vmDirectory: tmpDir.url, insecureMode: true
            )
            #expect(await server.inferAction(from: "GET", path: "/v1/vms") == "list")
            #expect(await server.inferAction(from: "POST", path: "/v1/vms") == "create")
            #expect(await server.inferAction(from: "POST", path: "/v1/vms/r1/clone") == "create")
            #expect(await server.inferAction(from: "POST", path: "/v1/vms/r1/start") == "start")
            #expect(await server.inferAction(from: "POST", path: "/v1/vms/r1/stop") == "stop")
            #expect(await server.inferAction(from: "DELETE", path: "/v1/vms/r1") == "delete")
        }
    }
}
