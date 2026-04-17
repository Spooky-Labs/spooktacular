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
