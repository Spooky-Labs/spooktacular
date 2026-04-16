import Foundation
import SpookCore

// MARK: - Federated Identity Verifier

/// Validates tokens from external identity providers (OIDC/SAML).
///
/// Infrastructure-layer implementations fetch provider metadata (JWKS,
/// discovery documents) and validate token signatures and claims. The
/// application layer depends only on this protocol.
///
/// ## Clean Architecture
///
/// This is a port — the application layer declares the interface, and
/// the infrastructure layer provides the adapter (e.g., ``OIDCTokenVerifier``).
public protocol FederatedIdentityVerifier: Sendable {
    /// Verifies a bearer token and returns the identity if valid.
    ///
    /// - Parameter token: A raw bearer token (JWT for OIDC, assertion for SAML).
    /// - Returns: The verified ``FederatedIdentity``.
    /// - Throws: If the token is malformed, expired, or fails signature validation.
    func verify(token: String) async throws -> FederatedIdentity
}

// MARK: - Federated Authorization

/// Authorization service for deployments that use federated identity
/// (OIDC / SAML) as the authentication front-end.
///
/// Every non-break-glass request still goes through role-based
/// permission checks via the injected ``RoleStore`` — identity and
/// authorization are **separate** concerns, and an authenticated
/// federated user has no inherent permission beyond what their roles
/// grant. Break-glass is gated by the ``TenantIsolationPolicy``.
///
/// ## Why this struct exists
///
/// An earlier version returned `true` for every non-break-glass
/// context ("identity verification happens upstream"), which is CWE-862
/// (Missing Authorization): authenticating as `alice@example.com`
/// should not by itself grant VM-delete permissions. This
/// implementation delegates role evaluation to ``RBACAuthorization``
/// so federated deployments enforce the same deny-by-default policy
/// as the non-federated path.
public struct FederatedAuthorization: AuthorizationService {
    private let rbac: RBACAuthorization
    private let isolation: any TenantIsolationPolicy

    public init(
        roleStore: any RoleStore,
        isolation: any TenantIsolationPolicy,
        policy: ReusePolicy = .singleTenant
    ) {
        self.rbac = RBACAuthorization(roleStore: roleStore, isolation: isolation)
        self.isolation = isolation
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // Break-glass requires an explicit tenant policy decision AND a
        // role-gated role:break-glass permission. Without both, a
        // signed token alone would be enough to obtain shell access —
        // which is exactly the footgun the reviewer flagged.
        if context.scope == .breakGlass {
            guard isolation.breakGlassAllowed(for: context.tenant) else { return false }
            return await rbac.authorize(context)
        }
        return await rbac.authorize(context)
    }
}
