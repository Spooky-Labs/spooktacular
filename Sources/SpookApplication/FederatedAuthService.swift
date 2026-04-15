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

/// Authorization service that supports both certificate and federated identity.
///
/// Delegates tenant isolation and break-glass policy to the injected
/// ``TenantIsolationPolicy``. This is intentionally simple — the
/// identity verification happens upstream in the ``FederatedIdentityVerifier``;
/// this service only checks authorization after identity is established.
public struct FederatedAuthorization: AuthorizationService {
    private let isolation: any TenantIsolationPolicy
    private let policy: ReusePolicy

    public init(isolation: any TenantIsolationPolicy, policy: ReusePolicy) {
        self.isolation = isolation
        self.policy = policy
    }

    public func authorize(_ context: AuthorizationContext) async -> Bool {
        // Break-glass requires explicit policy
        if context.scope == .breakGlass {
            return isolation.breakGlassAllowed(for: context.tenant)
        }
        return true
    }
}
