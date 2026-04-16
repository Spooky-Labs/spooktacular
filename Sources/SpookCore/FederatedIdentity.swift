import Foundation

/// A verified identity from an external identity provider.
///
/// After an OIDC or SAML token is validated, the verifier produces a
/// ``FederatedIdentity`` that the authorization layer uses for RBAC
/// decisions. The ``actorIdentity`` property is suitable for use in
/// ``AuthorizationContext``.
///
/// ## Clean Architecture
///
/// This is a domain value type — it depends only on Foundation and
/// carries no framework imports. Infrastructure-layer verifiers
/// (OIDC, SAML) create instances; the application layer consumes them.
public struct FederatedIdentity: Sendable, Codable, Equatable {
    /// The identity provider (e.g., "https://accounts.google.com", "okta.example.com").
    public let issuer: String
    /// The subject claim — unique user/service ID within the issuer.
    public let subject: String
    /// Display name (from name or preferred_username claim).
    public let displayName: String?
    /// Email address (from email claim).
    public let email: String?
    /// Groups/roles from the token (for RBAC mapping).
    public let groups: [String]
    /// When the token expires.
    public let expiresAt: Date?
    /// Raw claims for policy evaluation.
    public let claims: [String: String]

    public init(
        issuer: String,
        subject: String,
        displayName: String? = nil,
        email: String? = nil,
        groups: [String] = [],
        expiresAt: Date? = nil,
        claims: [String: String] = [:]
    ) {
        self.issuer = issuer
        self.subject = subject
        self.displayName = displayName
        self.email = email
        self.groups = groups
        self.expiresAt = expiresAt
        self.claims = claims
    }

    /// A string suitable for use as ``AuthorizationContext/actorIdentity``.
    public var actorIdentity: String { "\(issuer)/\(subject)" }

    /// Whether the token has expired.
    public var isExpired: Bool {
        guard let exp = expiresAt else { return false }
        return Date() > exp
    }

    /// Derives a ``FederatedIdentity`` from a SAML assertion.
    ///
    /// Prefers the `email` attribute when present, otherwise falls
    /// back to ``SAMLAssertion/nameID`` if the NameID format indicates
    /// an email address. Groups come from whichever of `groups`,
    /// `role`, or `memberOf` the IdP returned.
    ///
    /// Per Swift API Design Guidelines, this is a failable-free
    /// initializer on the destination type rather than a
    /// `to{Target}()` method on the source.
    public init(saml assertion: SAMLAssertion) {
        let groups = assertion.attributes["groups"]
            ?? assertion.attributes["role"]
            ?? assertion.attributes["memberOf"]
            ?? []
        let email = assertion.attributes["email"]?.first
            ?? (assertion.nameIDFormat?.contains("emailAddress") == true ? assertion.nameID : nil)
        self.init(
            issuer: assertion.issuer,
            subject: assertion.nameID,
            displayName: assertion.attributes["displayName"]?.first,
            email: email,
            groups: groups,
            expiresAt: assertion.sessionExpiresAt,
            claims: assertion.attributes.mapValues { $0.joined(separator: ",") }
        )
    }
}

// MARK: - OIDC Provider Configuration

/// Configuration for an OIDC identity provider.
///
/// Maps the provider's group claims to Spooktacular ``AuthScope`` values
/// and tenant IDs, enabling federated RBAC without local user management.
public struct OIDCProviderConfig: Sendable, Codable {
    /// The issuer URL (must match the `iss` claim in tokens).
    public let issuerURL: String
    /// The OAuth 2.0 client ID registered with the provider.
    public let clientID: String
    /// Expected audience claim. When non-nil, tokens must contain this value.
    public let audience: String?
    /// Map OIDC groups to Spooktacular scopes.
    public let groupScopeMapping: [String: AuthScope]
    /// Map OIDC groups to tenant IDs.
    public let groupTenantMapping: [String: String]

    public init(
        issuerURL: String,
        clientID: String,
        audience: String? = nil,
        groupScopeMapping: [String: AuthScope] = [:],
        groupTenantMapping: [String: String] = [:]
    ) {
        self.issuerURL = issuerURL
        self.clientID = clientID
        self.audience = audience
        self.groupScopeMapping = groupScopeMapping
        self.groupTenantMapping = groupTenantMapping
    }
}
