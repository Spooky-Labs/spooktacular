import Foundation

// MARK: - RBAC Model (OWASP + Casbin PERM)

/// A resource + action permission following the Casbin PERM model.
///
/// Permissions are the atomic unit of access control. Each permission
/// grants the ability to perform one action on one resource type.
///
/// ## Standards
/// - OWASP Authorization Cheat Sheet: deny-by-default
/// - Casbin PERM: subject + domain + object + action
/// - NIST SP 800-162: attribute-based access control foundation
public struct Permission: Sendable, Codable, Hashable {
    /// The resource type (e.g., "vm", "pool", "runner-group", "host", "audit").
    public let resource: String
    /// The action (e.g., "create", "start", "stop", "delete", "list", "exec", "drain").
    public let action: String

    public init(resource: String, action: String) {
        self.resource = resource
        self.action = action
    }
}

/// A named role within a tenant.
///
/// Roles aggregate permissions and are assigned to actors. Following
/// OWASP's deny-by-default principle, an actor has no permissions
/// until explicitly assigned a role.
public struct Role: Sendable, Codable, Hashable {
    public let id: String
    public let tenant: TenantID
    public let name: String
    public let permissions: Set<Permission>

    public init(id: String, tenant: TenantID, name: String, permissions: Set<Permission>) {
        self.id = id
        self.tenant = tenant
        self.name = name
        self.permissions = permissions
    }

    /// Whether this role grants a specific permission.
    public func allows(_ permission: Permission) -> Bool {
        permissions.contains(permission)
    }

    /// Whether this role grants a permission for a resource + action.
    public func allows(resource: String, action: String) -> Bool {
        allows(Permission(resource: resource, action: action))
    }

    /// Role equality requires identifier, tenant, **and** the
    /// granted permission set to match.
    ///
    /// A role's identity isn't just its name: two JSON role stores
    /// claiming to serve `"ci-operator"` but with divergent
    /// permissions are not the same role, and hashing them as
    /// equal would let a stale ConfigMap shadow a freshly-loaded
    /// one without any diff visible to the authorization code.
    public static func == (lhs: Role, rhs: Role) -> Bool {
        lhs.id == rhs.id
            && lhs.tenant == rhs.tenant
            && lhs.permissions == rhs.permissions
    }

    /// Hash combines identity and the permission `Set` so equal
    /// roles consistently hash to the same bucket and diverging
    /// permissions produce diverging hashes.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(tenant)
        hasher.combine(permissions)
    }
}

/// Assigns a role to an actor within a tenant.
public struct RoleAssignment: Sendable, Codable {
    public let actorIdentity: String
    public let tenant: TenantID
    public let role: String
    public let assignedAt: Date
    public let expiresAt: Date?

    public init(actorIdentity: String, tenant: TenantID, role: String,
                assignedAt: Date = Date(), expiresAt: Date? = nil) {
        self.actorIdentity = actorIdentity
        self.tenant = tenant
        self.role = role
        self.assignedAt = assignedAt
        self.expiresAt = expiresAt
    }

    public var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() > exp
    }
}

// MARK: - Built-In Roles (OWASP Deny-by-Default)

/// Predefined roles following OWASP's deny-by-default principle.
///
/// Each role grants the minimum permissions needed for its function.
/// Roles are hierarchical: ci-operator includes viewer permissions,
/// platform-admin includes ci-operator permissions.
public enum BuiltInRole {
    private static let viewerPerms: Set<Permission> = [
        Permission(resource: "vm", action: "list"),
        Permission(resource: "pool", action: "list"),
        Permission(resource: "runner-group", action: "list"),
        Permission(resource: "host", action: "list"),
        Permission(resource: "audit", action: "list"),
    ]

    public static func viewer(tenant: TenantID = .default) -> Role {
        Role(id: "viewer", tenant: tenant, name: "Viewer", permissions: viewerPerms)
    }

    public static func ciOperator(tenant: TenantID = .default) -> Role {
        Role(id: "ci-operator", tenant: tenant, name: "CI Operator", permissions: viewerPerms.union([
            Permission(resource: "vm", action: "create"),
            Permission(resource: "vm", action: "start"),
            Permission(resource: "vm", action: "stop"),
            Permission(resource: "pool", action: "schedule"),
        ]))
    }

    public static func platformAdmin(tenant: TenantID = .default) -> Role {
        Role(id: "platform-admin", tenant: tenant, name: "Platform Admin",
             permissions: ciOperator(tenant: tenant).permissions.union([
                Permission(resource: "vm", action: "delete"),
                Permission(resource: "pool", action: "create"),
                Permission(resource: "pool", action: "delete"),
                Permission(resource: "host", action: "drain"),
                Permission(resource: "runner-group", action: "manage"),
                // Tenant lifecycle via /v1/tenants. Ownership of
                // tenant creation is a platform-level (not
                // per-tenant) decision, but the permission still
                // lives in the tenant-scoped role set so callers
                // can't invoke these endpoints cross-tenant without
                // an assignment in the target tenant.
                Permission(resource: "tenant", action: "list"),
                Permission(resource: "tenant", action: "create"),
                Permission(resource: "tenant", action: "update"),
                Permission(resource: "tenant", action: "delete"),
             ]))
    }

    public static func securityAdmin(tenant: TenantID = .default) -> Role {
        Role(id: "security-admin", tenant: tenant, name: "Security Admin",
             permissions: viewerPerms.union([
                Permission(resource: "audit", action: "export"),
                Permission(resource: "audit", action: "verify"),
                Permission(resource: "host", action: "rotate-certs"),
                // Manage RBAC at runtime via /v1/roles. The HTTP
                // admin endpoints map to these specific actions
                // (not role:create) so we grant them explicitly
                // rather than relying on the generic verb map.
                Permission(resource: "role", action: "list"),
                Permission(resource: "role", action: "assign"),
                Permission(resource: "role", action: "revoke"),
                // Read-only view of the tenant roster for audit
                // reviews. Mutation stays exclusive to platform-admin
                // so a security reviewer can't inadvertently
                // reshape the tenancy while investigating.
                Permission(resource: "tenant", action: "list"),
                // Break-glass is a distinct permission gate on top
                // of the tenancy policy's allow decision. Without
                // it, any authenticated actor that requested
                // `scope: .breakGlass` got shell access whenever
                // the tenant permitted break-glass at all.
                Permission(resource: "break-glass", action: "invoke"),
             ]))
    }
}
