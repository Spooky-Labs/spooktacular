import Foundation
import SpooktacularCore
import SpooktacularApplication

/// RBAC role store backed by a JSON configuration file.
///
/// Reads roles and assignments from `SPOOKTACULAR_RBAC_CONFIG`. If no
/// config file is provided, loads built-in roles (viewer,
/// ci-operator, platform-admin, security-admin) with no
/// assignments.
///
/// ## Runtime persistence
///
/// Runtime `assign` / `revoke` calls (via the `/v1/roles` admin
/// API) are written back to the same config file atomically when
/// one was supplied at init. Without persistence, assignments
/// evaporate on restart — a Fortune-20 auditor's finding that
/// was flagged in the April 2026 readiness review. Operators who
/// want the old in-memory-only behavior can point SPOOKTACULAR_RBAC_CONFIG
/// at `/dev/null` or omit it; without a file, persistence is a
/// no-op and the admin API still functions.
///
/// Atomic write semantics: `Data.write(to:options:.atomic)`
/// writes to a temp file in the same directory then `rename(2)`s
/// it into place. A reader (another `spook serve` instance, or
/// an external audit tooling chain) either sees the old or the
/// new version — never a torn write.
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
    private let configPath: String?
    private let defaultTenant: TenantID

    /// Custom roles the config file defined (as opposed to the
    /// built-ins we always synthesize). Kept separate so
    /// persistence only rewrites what the operator actually
    /// authored — we never serialize the built-ins back to disk.
    private var customRoleIDs: Set<String> = []

    /// Creates a role store, defaulting to the shared
    /// `SpooktacularPaths.rbacConfig` path when no explicit
    /// path is supplied. Pass `configPath: ""` to force
    /// in-memory-only behavior (no persistence) — previously the
    /// silent default when the env var was unset.
    public init(configPath: String? = nil, defaultTenant: TenantID = .default) throws {
        // Empty string is the documented "in-memory-only" opt-out,
        // distinct from `nil` which means "use the default path."
        // This gives operators two clean intents: "use default"
        // (nil) or "don't persist" ("") — with no silent data-loss
        // path between them.
        let resolved: String?
        switch configPath {
        case nil:
            resolved = SpooktacularPaths.rbacConfig.path
        case "":
            resolved = nil
        case .some(let p):
            resolved = p
        }
        self.configPath = resolved
        self.defaultTenant = defaultTenant

        // Load built-in roles
        for role in [
            BuiltInRole.viewer(tenant: defaultTenant),
            BuiltInRole.ciOperator(tenant: defaultTenant),
            BuiltInRole.platformAdmin(tenant: defaultTenant),
            BuiltInRole.securityAdmin(tenant: defaultTenant),
        ] {
            roles[role.id] = role
        }

        // Override with config file if provided AND the file
        // exists. A missing file at the default path is expected
        // on first run — we materialize it lazily on first assign.
        if let path = resolved,
           let data = try? Data(contentsOf: URL(filePath: path)) {
            let config = try JSONDecoder().decode(RBACFileConfig.self, from: data)
            for rc in config.roles {
                let perms = Set(rc.permissions.map { Permission(resource: $0.resource, action: $0.action) })
                roles[rc.id] = Role(id: rc.id, tenant: defaultTenant, name: rc.name, permissions: perms)
                customRoleIDs.insert(rc.id)
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
        try persist()
    }

    public func revoke(actor: String, role: String, tenant: TenantID) async throws {
        assignments[actor]?.removeAll { $0.role == role && $0.tenant == tenant }
        if assignments[actor]?.isEmpty == true {
            assignments.removeValue(forKey: actor)
        }
        try persist()
    }

    // MARK: - Disk persistence

    /// Writes the current role + assignment state back to the
    /// configured path atomically. No-op when the store was
    /// initialized without a `configPath`, so in-process-only
    /// tests and transient deployments remain unaffected.
    ///
    /// The written file is always the canonical shape the
    /// loader expects, so a round-trip through disk + restart
    /// observes the same state the actor held at write time.
    private func persist() throws {
        guard let configPath else { return }
        // Materialize the parent directory on first write. The
        // default path is ~/.spooktacular/rbac.json — the root
        // may not exist on a fresh machine where `spook` has
        // never run before.
        let dir = URL(filePath: configPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )

        let roleConfigs = customRoleIDs.compactMap { id -> RBACFileConfig.RoleConfig? in
            guard let role = roles[id] else { return nil }
            let perms = role.permissions
                .map { RBACFileConfig.PermConfig(resource: $0.resource, action: $0.action) }
                .sorted { ($0.resource, $0.action) < ($1.resource, $1.action) }
            return RBACFileConfig.RoleConfig(id: id, name: role.name, permissions: perms)
        }.sorted { $0.id < $1.id }

        var assignmentConfigs: [RBACFileConfig.AssignmentConfig] = []
        for (actor, list) in assignments {
            for a in list where !a.isExpired {
                assignmentConfigs.append(.init(
                    actor: actor,
                    tenant: a.tenant.rawValue,
                    role: a.role
                ))
            }
        }
        assignmentConfigs.sort {
            ($0.actor, $0.role, $0.tenant ?? "") < ($1.actor, $1.role, $1.tenant ?? "")
        }

        let config = RBACFileConfig(roles: roleConfigs, assignments: assignmentConfigs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: URL(filePath: configPath), options: [.atomic])
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
