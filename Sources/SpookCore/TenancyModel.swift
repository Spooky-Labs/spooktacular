import Foundation

// MARK: - Tenancy Mode

/// The deployment trust model for a Spooktacular control plane.
///
/// Determines identity, authorization, scheduling, audit, and reuse
/// policies. Set once at startup — not changeable at runtime.
///
/// - ``singleTenant``: One customer team per trust domain. Shared
///   host pools, warm-pool reuse allowed with scrub validation,
///   break-glass shell available with admin controls.
/// - ``multiTenant``: Multiple teams or business units sharing
///   infrastructure. Host pools partitioned by tenant, no cross-tenant
///   warm-pool reuse, break-glass shell disabled by default, all
///   requests carry tenant identity.
public enum TenancyMode: String, Codable, Sendable {
    case singleTenant = "single-tenant"
    case multiTenant = "multi-tenant"
}

// MARK: - Identity Types

/// A unique identifier for a tenant (team, org, or business unit).
///
/// In single-tenant mode, there is exactly one TenantID. In
/// multi-tenant mode, every request, resource, and audit record
/// carries a TenantID.
public struct TenantID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The default tenant for single-tenant deployments.
    public static let `default` = TenantID("default")
}

/// A unique identifier for a host pool.
///
/// Host pools are partitioned by tenant in multi-tenant mode.
/// In single-tenant mode, all hosts belong to one pool.
public struct HostPoolID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The default pool for single-tenant deployments.
    public static let `default` = HostPoolID("default")
}

/// A unique identifier for a runner group.
///
/// Maps to GitHub's runner group concept. In multi-tenant mode,
/// runner groups are scoped to a tenant.
public struct RunnerGroupID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The default runner group.
    public static let `default` = RunnerGroupID("Default")
}

// MARK: - Authorization Context

/// The full authorization context for any control-plane request.
///
/// Every request — API call, reconciliation action, guest agent
/// command — must carry an authorization context. This is the
/// single type that authorization policies evaluate.
///
/// ## Six Invariants
///
/// 1. No tenantless request path.
/// 2. No cross-tenant warm-pool reuse.
/// 3. No bearer-token-only trust in multi-tenant mode.
/// 4. No break-glass shell in multi-tenant mode by default.
/// 5. No scheduler decision without tenant and host-pool filters.
/// 6. No audit record without tenant and actor identity.
public struct AuthorizationContext: Sendable {
    /// Who is making the request.
    public let actorIdentity: String

    /// Which tenant the actor belongs to.
    public let tenant: TenantID

    /// The capability scope of this request.
    public let scope: AuthScope

    /// The target resource (VM name, host name, pool name).
    public let resource: String

    /// The action being performed.
    public let action: String

    /// A unique ID for this request (for audit correlation).
    public let requestID: String

    public init(
        actorIdentity: String,
        tenant: TenantID,
        scope: AuthScope,
        resource: String,
        action: String,
        requestID: String = UUID().uuidString
    ) {
        self.actorIdentity = actorIdentity
        self.tenant = tenant
        self.scope = scope
        self.resource = resource
        self.action = action
        self.requestID = requestID
    }
}

/// The capability scope tiers for authorization.
public enum AuthScope: String, Codable, Sendable, Comparable {
    /// Read-only inspection: health, list, diagnostics.
    case read

    /// Runner lifecycle operations: start, stop, provision, scrub.
    case runner

    /// Full administrative operations (excluding shell).
    case admin

    /// Break-glass: raw shell, arbitrary file writes, app control.
    /// Disabled by default in multi-tenant mode.
    case breakGlass = "break-glass"

    private var order: Int {
        switch self {
        case .read: 0
        case .runner: 1
        case .admin: 2
        case .breakGlass: 3
        }
    }

    public static func < (lhs: AuthScope, rhs: AuthScope) -> Bool {
        lhs.order < rhs.order
    }
}

// MARK: - Reuse Policy

/// Controls how VMs are recycled between jobs.
///
/// In single-tenant mode, warm-pool reuse is allowed with scrub
/// validation. In multi-tenant mode, cross-tenant reuse is forbidden
/// and ephemeral mode is strongly recommended.
public struct ReusePolicy: Sendable, Codable {
    /// Whether warm-pool reuse is allowed at all.
    public let warmPoolAllowed: Bool

    /// Whether cross-tenant warm-pool reuse is allowed.
    /// Always `false` in multi-tenant mode.
    public let crossTenantReuseAllowed: Bool

    /// Whether break-glass shell is available.
    /// `false` by default in multi-tenant mode.
    public let breakGlassAllowed: Bool

    /// Whether ephemeral (destroy after each job) is the default.
    public let ephemeralDefault: Bool

    public init(
        warmPoolAllowed: Bool,
        crossTenantReuseAllowed: Bool,
        breakGlassAllowed: Bool,
        ephemeralDefault: Bool
    ) {
        self.warmPoolAllowed = warmPoolAllowed
        self.crossTenantReuseAllowed = crossTenantReuseAllowed
        self.breakGlassAllowed = breakGlassAllowed
        self.ephemeralDefault = ephemeralDefault
    }

    /// The default policy for single-tenant deployments.
    public static let singleTenant = ReusePolicy(
        warmPoolAllowed: true,
        crossTenantReuseAllowed: true,  // only one tenant exists
        breakGlassAllowed: true,
        ephemeralDefault: false
    )

    /// The default policy for multi-tenant deployments.
    public static let multiTenant = ReusePolicy(
        warmPoolAllowed: true,
        crossTenantReuseAllowed: false,
        breakGlassAllowed: false,
        ephemeralDefault: true
    )

    /// Returns the appropriate default policy for a tenancy mode.
    public static func `default`(for mode: TenancyMode) -> ReusePolicy {
        switch mode {
        case .singleTenant: .singleTenant
        case .multiTenant: .multiTenant
        }
    }
}

// MARK: - Audit Record

/// A structured audit record for every control-plane action.
///
/// Every action — API call, VM lifecycle event, guest agent command,
/// scheduler decision — produces an audit record. These are
/// forwarded to the configured ``AuditSink``.
public struct AuditRecord: Sendable, Codable {
    /// Unique ID for this audit entry.
    public let id: String

    /// When the action occurred.
    public let timestamp: Date

    /// Who performed the action.
    public let actorIdentity: String

    /// Which tenant the actor belongs to.
    public let tenant: TenantID

    /// The authorization scope used.
    public let scope: AuthScope

    /// The target resource.
    public let resource: String

    /// The action performed.
    public let action: String

    /// The outcome.
    public let outcome: AuditOutcome

    /// Correlation ID for tracing related actions.
    public let correlationID: String?

    public init(
        actorIdentity: String,
        tenant: TenantID,
        scope: AuthScope,
        resource: String,
        action: String,
        outcome: AuditOutcome,
        correlationID: String? = nil
    ) {
        self.id = UUID().uuidString
        self.timestamp = Date()
        self.actorIdentity = actorIdentity
        self.tenant = tenant
        self.scope = scope
        self.resource = resource
        self.action = action
        self.outcome = outcome
        self.correlationID = correlationID
    }

    /// Convenience initializer from an AuthorizationContext.
    public init(context: AuthorizationContext, outcome: AuditOutcome) {
        self.init(
            actorIdentity: context.actorIdentity,
            tenant: context.tenant,
            scope: context.scope,
            resource: context.resource,
            action: context.action,
            outcome: outcome,
            correlationID: context.requestID
        )
    }
}

/// The outcome of an audited action.
public enum AuditOutcome: String, Codable, Sendable {
    case success
    case denied
    case failed
    case timeout
}
