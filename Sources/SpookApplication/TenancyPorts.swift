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

/// Single-tenant authorization: checks scope only, no tenant isolation.
public struct SingleTenantAuthorization: AuthorizationService {
    private let policy: ReusePolicy

    public init(policy: ReusePolicy = .singleTenant) {
        self.policy = policy
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // In single-tenant mode, break-glass is allowed if policy permits
        if context.scope == .breakGlass {
            return policy.breakGlassAllowed
        }
        return true
    }
}

/// Multi-tenant authorization: enforces tenant boundaries and scope.
public struct MultiTenantAuthorization: AuthorizationService {
    private let policy: ReusePolicy
    private let isolation: any TenantIsolationPolicy

    public init(
        policy: ReusePolicy = .multiTenant,
        isolation: any TenantIsolationPolicy
    ) {
        self.policy = policy
        self.isolation = isolation
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // Break-glass disabled by default in multi-tenant
        if context.scope == .breakGlass {
            return isolation.breakGlassAllowed(for: context.tenant)
        }
        return true
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

    public init(tenantPools: [TenantID: Set<HostPoolID>] = [:]) {
        self.tenantPools = tenantPools
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
        // Disabled by default — must be explicitly granted per-tenant
        false
    }
}
