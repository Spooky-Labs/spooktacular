import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

/// Covers the runtime-assign → disk → reload contract that closes
/// the April 2026 enterprise-readiness finding: role assignments
/// made through `/v1/roles/assign` must survive process restart.
@Suite("JSONRoleStore persistence", .tags(.security, .integration))
struct JSONRoleStorePersistenceTests {

    /// Writes a minimal RBAC config file and returns its path.
    private func seedConfig(roles: [[String: Any]] = [], assignments: [[String: Any]] = []) throws -> String {
        let dir = NSTemporaryDirectory() + "rbac-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "rbac.json"
        let payload: [String: Any] = ["roles": roles, "assignments": assignments]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: URL(filePath: path))
        return path
    }

    @Test("assign() persists to disk")
    func assignPersists() async throws {
        let path = try seedConfig()
        let store = try JSONRoleStore(configPath: path)
        let assignment = RoleAssignment(
            actorIdentity: "oidc/alice@example.com",
            tenant: .default,
            role: "platform-admin"
        )
        try await store.assign(assignment)

        // Re-open from the same path; the assignment must still be
        // visible.
        let reloaded = try JSONRoleStore(configPath: path)
        let roles = try await reloaded.rolesForActor(
            "oidc/alice@example.com", tenant: .default
        )
        #expect(roles.contains(where: { $0.id == "platform-admin" }))
    }

    @Test("revoke() removes from disk")
    func revokePersists() async throws {
        let path = try seedConfig(assignments: [
            ["actor": "oidc/bob@example.com",
             "tenant": "default",
             "role": "ci-operator"],
        ])
        let store = try JSONRoleStore(configPath: path)
        try await store.revoke(actor: "oidc/bob@example.com", role: "ci-operator", tenant: .default)

        let reloaded = try JSONRoleStore(configPath: path)
        let roles = try await reloaded.rolesForActor(
            "oidc/bob@example.com", tenant: .default
        )
        #expect(roles.isEmpty, "Revoked role should not come back after reload")
    }

    @Test("nil configPath → no-op persist (in-memory only)")
    func nilPathNoOp() async throws {
        let store = try JSONRoleStore(configPath: nil)
        // Must not throw and must not crash.
        try await store.assign(RoleAssignment(
            actorIdentity: "oidc/carol@example.com",
            tenant: .default,
            role: "viewer"
        ))
        let roles = try await store.rolesForActor("oidc/carol@example.com", tenant: .default)
        #expect(roles.contains(where: { $0.id == "viewer" }))
    }

    @Test("atomic write: concurrent assigns produce a consistent final file")
    func concurrentAssignsConverge() async throws {
        let path = try seedConfig()
        let store = try JSONRoleStore(configPath: path)

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    try? await store.assign(RoleAssignment(
                        actorIdentity: "actor-\(i)",
                        tenant: .default,
                        role: "viewer"
                    ))
                }
            }
        }

        let reloaded = try JSONRoleStore(configPath: path)
        for i in 0..<20 {
            let roles = try await reloaded.rolesForActor("actor-\(i)", tenant: .default)
            #expect(roles.contains(where: { $0.id == "viewer" }),
                    "actor-\(i) must still have viewer after reload")
        }
    }
}
