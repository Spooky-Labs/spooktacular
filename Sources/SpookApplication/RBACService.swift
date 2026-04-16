import Foundation
import SpookCore

// MARK: - Role Store

/// Stores and retrieves roles and assignments.
///
/// Implementations: `JSONRoleStore` (file-based), or Kubernetes
/// ConfigMap/CRD-based for K8s deployments.
public protocol RoleStore: Sendable {
    func rolesForActor(_ identity: String, tenant: TenantID) async throws -> [Role]
    func allRoles(tenant: TenantID) async throws -> [Role]
    func assign(_ assignment: RoleAssignment) async throws
    func revoke(actor: String, role: String, tenant: TenantID) async throws
}

// MARK: - RBAC Authorization

/// Resource-level authorization using RBAC.
///
/// Replaces scope-only authorization with permission checks against
/// the actor's assigned roles. Deny by default per OWASP.
///
/// Flow: actor identity → look up roles in tenant → check if any
/// role has Permission(resource, action) → allow or deny.
public struct RBACAuthorization: AuthorizationService {
    private let roleStore: any RoleStore
    private let isolation: any TenantIsolationPolicy

    public init(roleStore: any RoleStore, isolation: any TenantIsolationPolicy) {
        self.roleStore = roleStore
        self.isolation = isolation
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // Break-glass requires explicit tenant-level permission
        if context.scope == .breakGlass {
            return isolation.breakGlassAllowed(for: context.tenant)
        }

        // Look up actor's roles — deny by default (OWASP)
        guard let roles = try? await roleStore.rolesForActor(
            context.actorIdentity, tenant: context.tenant
        ), !roles.isEmpty else {
            return false
        }

        // Check if any role grants the needed permission
        let needed = Permission(resource: context.resource, action: context.action)
        return roles.contains { $0.allows(needed) }
    }
}

// MARK: - IdP Registry

/// Unified IdP configuration (OIDC or SAML).
public enum IdPConfig: Sendable, Codable {
    case oidc(OIDCProviderConfig)
    case saml(SAMLProviderConfig)

    public var issuer: String {
        switch self {
        case .oidc(let c): return c.issuerURL
        case .saml(let c): return c.entityID
        }
    }

    enum CodingKeys: String, CodingKey { case type, config }
    enum ConfigType: String, Codable { case oidc, saml }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .oidc(let c):
            try container.encode(ConfigType.oidc, forKey: .type)
            try container.encode(c, forKey: .config)
        case .saml(let c):
            try container.encode(ConfigType.saml, forKey: .type)
            try container.encode(c, forKey: .config)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ConfigType.self, forKey: .type)
        switch type {
        case .oidc: self = .oidc(try container.decode(OIDCProviderConfig.self, forKey: .config))
        case .saml: self = .saml(try container.decode(SAMLProviderConfig.self, forKey: .config))
        }
    }
}

/// Registry of identity providers for plug-and-play multi-IdP support.
public protocol IdPRegistry: Sendable {
    func register(_ config: IdPConfig) async throws
    func remove(issuer: String) async throws
    func verifierFor(issuer: String) async -> (any FederatedIdentityVerifier)?
    func allProviders() async -> [IdPConfig]
}

// MARK: - Immutable Audit Store

/// Append-only storage backend for audit records.
///
/// Records can be written but never modified or deleted. This is
/// the storage-layer complement to MerkleAuditSink's tamper-evidence:
/// together they satisfy SOC 2 Type II.
///
/// ## Standards
/// - NIST SP 800-53 AU-9: Protection of audit information
/// - SOC 2 Type II CC7.2: Monitoring of system components
public protocol ImmutableAuditStore: Sendable {
    /// Appends a record. Returns the storage-assigned sequence number.
    func append(_ record: AuditRecord) async throws -> UInt64
    /// Reads records in a range.
    func read(from: UInt64, count: Int) async throws -> [AuditRecord]
    /// Returns the current record count.
    func recordCount() async throws -> UInt64
}
