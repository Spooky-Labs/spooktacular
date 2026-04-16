import Testing

/// Domain tags for cross-cutting test categorization.
///
/// Use these to filter tests by concern:
/// ```bash
/// swift test --filter .security    # all security tests
/// swift test --filter .integration # integration tests only
/// swift test --filter .lifecycle   # VM lifecycle tests
/// ```
extension Tag {
    /// Tests for authentication, authorization, RBAC, and access control.
    @Tag static var security: Self

    /// Tests for role-based access control specifically.
    @Tag static var rbac: Self

    /// Tests for audit logging, Merkle trees, and compliance.
    @Tag static var audit: Self

    /// Tests for OIDC, SAML, and federated identity.
    @Tag static var identity: Self

    /// Tests for VM lifecycle, state machines, and runner pools.
    @Tag static var lifecycle: Self

    /// Tests for networking, IP resolution, MAC addresses, vsock.
    @Tag static var networking: Self

    /// Tests for VM infrastructure: cloning, snapshots, capacity.
    @Tag static var infrastructure: Self

    /// Integration tests that verify component interactions.
    @Tag static var integration: Self

    /// Tests for configuration, env vars, and data models.
    @Tag static var configuration: Self

    /// Tests for cryptographic operations: HMAC, signatures, keys.
    @Tag static var cryptography: Self

    /// Tests for GitHub/CI runner template generation.
    @Tag static var template: Self

    /// Tests for SOC 2, FIPS, and regulatory compliance.
    @Tag static var compliance: Self

    /// Tests for CLI commands (spook doctor, spook rbac, etc.).
    @Tag static var cli: Self

    /// Tests for the Kubernetes controller and reconciler.
    @Tag static var controller: Self
}
