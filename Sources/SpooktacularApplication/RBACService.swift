import Foundation
import SpooktacularCore

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

// MARK: - Authorization Outcome

/// Rich outcome from an authorization decision.
///
/// The plain `Bool` contract used by ``AuthorizationService``
/// collapses two very different situations into the same `false`:
///
/// - A deliberate **deny** — the actor has no role granting the
///   requested permission. Operators see this during day-to-day
///   enforcement; it's the OWASP deny-by-default outcome.
/// - A **transient error** — the role store threw on
///   ``RoleStore/rolesForActor(_:tenant:)`` (network blip, disk
///   read failure, corrupted ConfigMap). Collapsing this to
///   `false` looks identical to a deny in audit logs, hiding
///   availability incidents that operators must actually page on.
///
/// ``AuthzOutcome`` preserves the distinction. Callers that want
/// the legacy boolean can use ``allowed`` and a policy of
/// fail-closed (errors treated as deny) while the audit pipeline
/// records the real outcome.
public enum AuthzOutcome: Sendable, Equatable {

    /// The actor is permitted to perform the action.
    case allow

    /// The actor is explicitly denied.
    case deny

    /// The role store failed to answer. The action is fail-closed
    /// (``allowed`` returns `false`) but operators can distinguish
    /// this from a deliberate deny in audit trails.
    ///
    /// - Parameter transient: The error that prevented a decision.
    case error(transient: any Error)

    /// `true` when the outcome is ``allow``; fail-closed otherwise.
    public var allowed: Bool {
        if case .allow = self { return true }
        return false
    }

    public static func == (lhs: AuthzOutcome, rhs: AuthzOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.allow, .allow), (.deny, .deny): return true
        case (.error(let a), .error(let b)):
            return String(describing: a) == String(describing: b)
        default:
            return false
        }
    }
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
    private let auditSink: (any AuditSink)?
    private let logger: any LogProvider

    public init(
        roleStore: any RoleStore,
        isolation: any TenantIsolationPolicy,
        auditSink: (any AuditSink)? = nil,
        logger: any LogProvider = SilentLogProvider()
    ) {
        self.roleStore = roleStore
        self.isolation = isolation
        self.auditSink = auditSink
        self.logger = logger
    }

    /// Fail-closed boolean required by ``AuthorizationService``.
    ///
    /// Both deny and role-store errors surface as `false` so existing
    /// gate code keeps the OWASP deny-by-default posture. Callers
    /// that need to distinguish availability outages from policy
    /// denies should use ``authorizeDetailed(_:)``.
    public func authorize(_ context: AuthorizationContext) async -> Bool {
        await authorizeDetailed(context).allowed
    }

    /// Full-fidelity authorization decision.
    ///
    /// Returns ``AuthzOutcome/allow``, ``AuthzOutcome/deny``, or
    /// ``AuthzOutcome/error(transient:)``. Every decision is logged
    /// at `.debug` through the injected ``LogProvider``; deny and
    /// error outcomes are additionally teed to an ``AuditSink`` when
    /// one is configured.
    public func authorizeDetailed(_ context: AuthorizationContext) async -> AuthzOutcome {
        let outcome = await decide(context)
        logger.debug(
            "rbac decision actor=\(context.actorIdentity) tenant=\(context.tenant.rawValue) resource=\(context.resource) action=\(context.action) outcome=\(String(describing: outcome))"
        )
        await recordAudit(context: context, outcome: outcome)
        return outcome
    }

    private func decide(_ context: AuthorizationContext) async -> AuthzOutcome {
        // Break-glass requires explicit tenant-level permission
        if context.scope == .breakGlass {
            return isolation.breakGlassAllowed(for: context.tenant)
                ? .allow : .deny
        }

        // Look up actor's roles. A throw is a transient error, NOT a
        // deny — operators must be able to page on role-store outages.
        let roles: [Role]
        do {
            roles = try await roleStore.rolesForActor(
                context.actorIdentity, tenant: context.tenant
            )
        } catch {
            logger.error(
                "rbac role-store failure actor=\(context.actorIdentity) error=\(error.localizedDescription)"
            )
            return .error(transient: error)
        }
        guard !roles.isEmpty else { return .deny }

        // Check if any role grants the needed permission (deny by
        // default per OWASP).
        let needed = Permission(resource: context.resource, action: context.action)
        return roles.contains { $0.allows(needed) } ? .allow : .deny
    }

    private func recordAudit(
        context: AuthorizationContext,
        outcome: AuthzOutcome
    ) async {
        guard let sink = auditSink else { return }
        let auditOutcome: AuditOutcome
        switch outcome {
        case .allow:  return   // allow is the happy path; don't spam
        case .deny:   auditOutcome = .denied
        case .error:  auditOutcome = .failed
        }
        // AuditSink.record is `async throws`. A decision-time audit
        // failure is a SOC 2 AU-9 concern: we cannot authorize
        // without a durable trail. However, RBAC denials and errors
        // are already being returned to the caller — the outer HTTP
        // layer converts them to 4xx/5xx — so surfacing a second
        // error here would shadow the primary decision. Log the
        // audit-write failure through the injected LogProvider so
        // operators have a Console-discoverable signal, then return.
        do {
            try await sink.record(
                AuditRecord(context: context, outcome: auditOutcome)
            )
        } catch {
            logger.error(
                "rbac audit-write failure actor=\(context.actorIdentity) outcome=\(String(describing: auditOutcome)) error=\(error.localizedDescription)"
            )
        }
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
