import Foundation
import SpookCore

// MARK: - Authorization Service

/// Evaluates whether an action is permitted given the authorization context.
///
/// The implementation is tenancy-mode-aware: single-tenant mode uses
/// simpler scope checks, while multi-tenant mode enforces tenant
/// isolation, cross-tenant reuse prevention, and break-glass restrictions.
public protocol AuthorizationService: Sendable {
    /// Evaluates whether the given context permits the action.
    ///
    /// - Returns: `true` if authorized, `false` if denied.
    func authorize(_ context: AuthorizationContext) async -> Bool
}

// MARK: - Tenant Isolation Policy

/// Enforces tenant boundaries for scheduling and resource access.
///
/// In single-tenant mode, this is a pass-through. In multi-tenant mode,
/// it ensures host pools, warm pools, and runner groups are partitioned
/// by tenant.
public protocol TenantIsolationPolicy: Sendable {
    /// Returns whether a tenant can schedule onto a host pool.
    func canSchedule(tenant: TenantID, onto pool: HostPoolID) -> Bool

    /// Returns whether a VM can be reused by a tenant.
    func canReuse(vm: String, fromTenant: TenantID, forTenant: TenantID) -> Bool

    /// Returns whether break-glass operations are permitted for a tenant.
    func breakGlassAllowed(for tenant: TenantID) -> Bool
}

// MARK: - Audit Sink

/// Receives structured audit records and forwards them to storage.
///
/// Implementations may write to os.Logger, forward to a SIEM,
/// append to a file, or publish to an event stream. The key contract:
/// every control-plane action produces exactly one audit record.
public protocol AuditSink: Sendable {
    /// Records an audit event.
    func record(_ entry: AuditRecord) async
}

// MARK: - Default Implementations

/// Single-tenant authorization with optional RBAC.
///
/// When a `RoleStore` is provided, checks resource-level permissions
/// (deny-by-default per OWASP). Without a role store, falls back to
/// scope-based authorization for backward compatibility.
public struct SingleTenantAuthorization: AuthorizationService {
    private let policy: ReusePolicy
    private let roleStore: (any RoleStore)?

    public init(policy: ReusePolicy = .singleTenant, roleStore: (any RoleStore)? = nil) {
        self.policy = policy
        self.roleStore = roleStore
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        if context.scope == .breakGlass {
            return policy.breakGlassAllowed
        }
        // If RBAC is configured, enforce resource-level permissions
        if let store = roleStore {
            guard let roles = try? await store.rolesForActor(
                context.actorIdentity, tenant: context.tenant
            ), !roles.isEmpty else {
                return false // deny by default (OWASP)
            }
            let needed = Permission(resource: context.resource, action: context.action)
            return roles.contains { $0.allows(needed) }
        }
        // Legacy fallback: scope-based only (no role store configured)
        return true
    }
}

/// Multi-tenant authorization with mandatory RBAC.
///
/// Always checks resource-level permissions via `RoleStore`.
/// Deny by default per OWASP. Break-glass requires explicit
/// per-tenant opt-in via `TenantIsolationPolicy`.
public struct MultiTenantAuthorization: AuthorizationService {
    private let policy: ReusePolicy
    private let isolation: any TenantIsolationPolicy
    private let roleStore: any RoleStore

    public init(
        policy: ReusePolicy = .multiTenant,
        isolation: any TenantIsolationPolicy,
        roleStore: any RoleStore
    ) {
        self.policy = policy
        self.isolation = isolation
        self.roleStore = roleStore
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // Break-glass requires explicit tenant-level permission
        if context.scope == .breakGlass {
            return isolation.breakGlassAllowed(for: context.tenant)
        }
        // RBAC: deny by default, check resource-level permissions
        guard let roles = try? await roleStore.rolesForActor(
            context.actorIdentity, tenant: context.tenant
        ), !roles.isEmpty else {
            return false
        }
        let needed = Permission(resource: context.resource, action: context.action)
        return roles.contains { $0.allows(needed) }
    }
}

/// Single-tenant isolation: everything is allowed (one trust domain).
public struct SingleTenantIsolation: TenantIsolationPolicy {
    public init() {}

    public func canSchedule(tenant: TenantID, onto pool: HostPoolID) -> Bool { true }
    public func canReuse(vm: String, fromTenant: TenantID, forTenant: TenantID) -> Bool { true }
    public func breakGlassAllowed(for tenant: TenantID) -> Bool { true }
}

/// Multi-tenant isolation: strict tenant boundaries.
public struct MultiTenantIsolation: TenantIsolationPolicy {
    /// Maps tenants to their permitted host pools.
    private let tenantPools: [TenantID: Set<HostPoolID>]

    /// Tenants explicitly granted break-glass access.
    private let breakGlassTenants: Set<TenantID>

    public init(
        tenantPools: [TenantID: Set<HostPoolID>] = [:],
        breakGlassTenants: Set<TenantID> = []
    ) {
        self.tenantPools = tenantPools
        self.breakGlassTenants = breakGlassTenants
    }

    public func canSchedule(tenant: TenantID, onto pool: HostPoolID) -> Bool {
        guard let pools = tenantPools[tenant] else { return false }
        return pools.contains(pool)
    }

    public func canReuse(vm: String, fromTenant: TenantID, forTenant: TenantID) -> Bool {
        // Cross-tenant reuse is never allowed
        fromTenant == forTenant
    }

    public func breakGlassAllowed(for tenant: TenantID) -> Bool {
        breakGlassTenants.contains(tenant)
    }
}
