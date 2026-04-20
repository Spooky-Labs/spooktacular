import Foundation
import SpooktacularCore

/// A precondition check that refuses to start `spook serve` when a
/// deployment that advertises itself as production-grade is missing
/// controls an enterprise operator must NOT accidentally skip.
///
/// ## What this replaces
///
/// The HTTP listener itself already fails closed when TLS or the
/// API token is absent in production (`HTTPAPIServerError.tlsRequired`
/// / `HTTPAPIServerError.missingAPIToken`). That catches the two
/// most obvious footguns. It does NOT catch the subtler ones an
/// auditor routinely flags:
///
/// - multi-tenant mode running without any audit sink (no durable
///   record of cross-tenant actions),
/// - multi-tenant mode running without an authorization service
///   (every caller treated as a single principal — no RBAC),
/// - `insecure` mode combined with `multi-tenant` (the bypass flag
///   was designed for laptop dev, not a fleet).
///
/// `ProductionPreflight` closes those gaps. It is pure domain logic
/// (no Foundation-network, no Apple SDK imports) and therefore lives
/// in `SpooktacularApplication`, where it can be unit-tested without
/// spinning up a listener.
///
/// ## Call site
///
/// `spook serve` invokes `validate()` after wiring the stack and
/// before constructing the `HTTPAPIServer`. A failure throws
/// `ProductionPreflightError`; the CLI prints the description +
/// recovery hint and exits non-zero. There is no "warn and
/// continue" fallback — that is precisely the behavior the
/// enterprise review flagged.
public struct ProductionPreflight: Sendable {

    public let tenancyMode: TenancyMode
    public let insecure: Bool
    public let hasAuthorizationService: Bool
    public let hasAuditSink: Bool

    /// Whether a fleet-wide ``DistributedLockService`` is wired.
    /// Multi-tenant deployments MUST have one — nonce replay
    /// protection, quota admission, and runner-pool reconciliation
    /// all devolve into per-process races without it, which in
    /// multi-tenant gets tagged as a tenant-isolation break.
    public let hasDistributedLockService: Bool

    public init(
        tenancyMode: TenancyMode,
        insecure: Bool,
        hasAuthorizationService: Bool,
        hasAuditSink: Bool,
        hasDistributedLockService: Bool = false
    ) {
        self.tenancyMode = tenancyMode
        self.insecure = insecure
        self.hasAuthorizationService = hasAuthorizationService
        self.hasAuditSink = hasAuditSink
        self.hasDistributedLockService = hasDistributedLockService
    }

    /// Throws the first precondition violation encountered.
    ///
    /// Ordering rationale:
    ///
    /// 1. `insecure` in multi-tenant is reported first because it
    ///    subsumes the other failures — an insecure server has no
    ///    meaningful authorization story even if a roleStore were
    ///    loaded.
    /// 2. Missing authorization is next: a caller who gets through
    ///    an un-RBAC'd path does so with no record of having done
    ///    so, and an audit sink can't observe a request that never
    ///    hit the authorization gate.
    /// 3. Audit is required for **any** non-insecure production
    ///    boot — not just multi-tenant. A single-tenant Fortune-20
    ///    deployment with no durable record of cross-host actions
    ///    is an audit finding on day one. Operators who genuinely
    ///    want to run without durable audit must pass `--insecure`
    ///    explicitly and accept the warning banner; there is no
    ///    silent fallback.
    public func validate() throws {
        if tenancyMode == .multiTenant && insecure {
            throw ProductionPreflightError.insecureModeInMultiTenant
        }
        if tenancyMode == .multiTenant && !hasAuthorizationService {
            throw ProductionPreflightError.multiTenantRequiresAuthorization
        }
        // Audit is required for every production (non-insecure)
        // deployment, regardless of tenancy mode. Previously this
        // check only fired in multi-tenant — which silently
        // exempted the most common enterprise deployment shape
        // (single-tenant with federated identity) from the
        // fail-closed audit guarantee the hardening guide
        // advertises.
        if !insecure && !hasAuditSink {
            throw ProductionPreflightError.productionRequiresAudit
        }
        // Fleet-wide coordination is required in multi-tenant
        // mode. Without a distributed lock backend the per-process
        // replay cache, quota reservation, and pool reconciler
        // all race across controllers — a "multi-tenant"
        // deployment that accepts two concurrent creations from
        // the same tenant because the host-A controller couldn't
        // see host-B's reservation is not multi-tenant at all.
        if tenancyMode == .multiTenant && !hasDistributedLockService {
            throw ProductionPreflightError.multiTenantRequiresDistributedLock
        }
    }
}

// MARK: - Errors

/// Hard-fail preconditions enforced by `ProductionPreflight`.
///
/// Each case carries its own recovery guidance so the CLI can
/// render a message an operator can act on without reading source.
public enum ProductionPreflightError: Error, LocalizedError, Sendable, Equatable {
    /// `SPOOKTACULAR_TENANCY_MODE=multi-tenant` combined with `--insecure`.
    case insecureModeInMultiTenant

    /// Multi-tenant mode with no configured `AuthorizationService`.
    case multiTenantRequiresAuthorization

    /// Any non-insecure production boot with no configured `AuditSink`.
    case productionRequiresAudit

    /// Multi-tenant mode with no configured
    /// ``DistributedLockService``. The coordination primitives
    /// (replay cache, quota reservation, pool reconciler) all
    /// devolve to per-process races without a fleet-wide lock.
    case multiTenantRequiresDistributedLock

    public var errorDescription: String? {
        switch self {
        case .insecureModeInMultiTenant:
            "Refusing to start: --insecure is not permitted in multi-tenant mode."
        case .multiTenantRequiresAuthorization:
            "Refusing to start: multi-tenant mode requires a configured AuthorizationService (RBAC)."
        case .productionRequiresAudit:
            "Refusing to start: production deployments require an audit sink. No SPOOKTACULAR_AUDIT_FILE / SPOOKTACULAR_AUDIT_IMMUTABLE_PATH / SPOOKTACULAR_AUDIT_MERKLE was configured."
        case .multiTenantRequiresDistributedLock:
            "Refusing to start: multi-tenant mode requires a DistributedLockService. None of SPOOKTACULAR_DYNAMO_TABLE / SPOOK_K8S_API / SPOOKTACULAR_LOCK_DIR was configured."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .insecureModeInMultiTenant:
            "Drop --insecure, provide --tls-cert / --tls-key, and set SPOOKTACULAR_API_TOKEN (or federated identity). Multi-tenant mode cannot run without TLS + authentication."
        case .multiTenantRequiresAuthorization:
            "Provide SPOOKTACULAR_RBAC_CONFIG pointing at a JSONRoleStore file, or drop back to SPOOKTACULAR_TENANCY_MODE=single-tenant."
        case .productionRequiresAudit:
            "Set at minimum SPOOKTACULAR_AUDIT_FILE. For SOC 2 Type II, combine with SPOOKTACULAR_AUDIT_IMMUTABLE_PATH, SPOOKTACULAR_AUDIT_MERKLE=1 + SPOOKTACULAR_AUDIT_SIGNING_KEY, and SPOOK_AUDIT_S3_BUCKET (Object Lock). Operators who genuinely need to run without audit must pass --insecure explicitly."
        case .multiTenantRequiresDistributedLock:
            "Set SPOOKTACULAR_DYNAMO_TABLE (cross-region) or SPOOK_K8S_API (single-cluster) to select a distributed backend. SPOOKTACULAR_LOCK_DIR on a shared NFS mount is acceptable only on a single-host deployment and is not valid with SPOOKTACULAR_TENANCY_MODE=multi-tenant."
        }
    }
}
