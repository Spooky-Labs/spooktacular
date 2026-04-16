import Foundation
import SpookCore
import SpookApplication

/// RBAC role store backed by a JSON configuration file.
///
/// Reads roles and assignments from `SPOOK_RBAC_CONFIG`. If no
/// config file is provided, loads built-in roles (viewer, ci-operator,
/// platform-admin, security-admin) with no assignments.
///
/// ## Configuration file format
///
/// ```json
/// {
///   "roles": [
///     {"id": "custom-role", "name": "Custom", "permissions": [
///       {"resource": "vm", "action": "start"}
///     ]}
///   ],
///   "assignments": [
///     {"actor": "oidc/user@example.com", "tenant": "team-a", "role": "ci-operator"}
///   ]
/// }
/// ```
public actor JSONRoleStore: RoleStore {
    private var roles: [String: Role] = [:]
    private var assignments: [String: [RoleAssignment]] = [:]  // keyed by actorIdentity

    public init(configPath: String? = nil, defaultTenant: TenantID = .default) throws {
        // Load built-in roles
        for role in [
            BuiltInRole.viewer(tenant: defaultTenant),
            BuiltInRole.ciOperator(tenant: defaultTenant),
            BuiltInRole.platformAdmin(tenant: defaultTenant),
            BuiltInRole.securityAdmin(tenant: defaultTenant),
        ] {
            roles[role.id] = role
        }

        // Override with config file if provided
        if let path = configPath,
           let data = try? Data(contentsOf: URL(filePath: path)) {
            let config = try JSONDecoder().decode(RBACFileConfig.self, from: data)
            for rc in config.roles {
                let perms = Set(rc.permissions.map { Permission(resource: $0.resource, action: $0.action) })
                roles[rc.id] = Role(id: rc.id, tenant: defaultTenant, name: rc.name, permissions: perms)
            }
            for ac in config.assignments ?? [] {
                let assignment = RoleAssignment(
                    actorIdentity: ac.actor,
                    tenant: TenantID(ac.tenant ?? "default"),
                    role: ac.role
                )
                assignments[ac.actor, default: []].append(assignment)
            }
        }
    }

    public func rolesForActor(_ identity: String, tenant: TenantID) async throws -> [Role] {
        let actorAssignments = assignments[identity] ?? []
        return actorAssignments
            .filter { $0.tenant == tenant && !$0.isExpired }
            .compactMap { roles[$0.role] }
    }

    public func allRoles(tenant: TenantID) async throws -> [Role] {
        Array(roles.values.filter { $0.tenant == tenant })
    }

    public func assign(_ assignment: RoleAssignment) async throws {
        assignments[assignment.actorIdentity, default: []].append(assignment)
    }

    public func revoke(actor: String, role: String, tenant: TenantID) async throws {
        assignments[actor]?.removeAll { $0.role == role && $0.tenant == tenant }
    }
}

// MARK: - Config File Model

private struct RBACFileConfig: Codable {
    let roles: [RoleConfig]
    let assignments: [AssignmentConfig]?

    struct RoleConfig: Codable {
        let id: String
        let name: String
        let permissions: [PermConfig]
    }

    struct PermConfig: Codable {
        let resource: String
        let action: String
    }

    struct AssignmentConfig: Codable {
        let actor: String
        let tenant: String?
        let role: String
    }
}
