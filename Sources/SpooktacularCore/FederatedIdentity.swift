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

    /// Whether the token has expired, evaluated against `now`.
    ///
    /// Injectable `now` matches the ``BreakGlassTicket/isExpired(now:clockSkew:)``
    /// style — callers can pass a fixed reference date for
    /// deterministic tests and tests can simulate skew without
    /// waiting wall-clock. Tokens without an `expiresAt` are
    /// considered non-expiring (e.g. service-account identities
    /// derived from static config).
    public func isExpired(now: Date = Date()) -> Bool {
        guard let exp = expiresAt else { return false }
        return now > exp
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
    /// Expected audience claim. **Required** — tokens must
    /// contain this value in their `aud` claim or be rejected.
    ///
    /// OIDC Core §3.1.3.7 requires audience validation; shared-
    /// issuer IdPs (GitHub Actions, Azure AD multi-tenant,
    /// Google) make audience the only thing separating a token
    /// minted for service A from a token minted for service B.
    /// A `nil`-audience code path therefore invites cross-client
    /// confusion every time, so the field is now non-optional.
    /// Callers that previously used `clientID` as the audience
    /// should pass `audience: clientID` explicitly.
    public let audience: String
    /// Map OIDC groups to Spooktacular scopes.
    public let groupScopeMapping: [String: AuthScope]
    /// Map OIDC groups to tenant IDs.
    public let groupTenantMapping: [String: String]

    /// File path to a static JWKS JSON document.
    ///
    /// When set, the verifier loads the provider's keys from disk
    /// instead of calling the issuer's `/.well-known/openid-configuration`
    /// and `jwks_uri` over the network. This is the strongest defense
    /// against an on-path attacker manipulating the JWKS fetch — the
    /// keys live at rest on the host, signed into config management,
    /// and rotate on the operator's schedule rather than the IdP's
    /// network availability.
    ///
    /// Expected format is the standard JWKS document:
    /// `{"keys":[{"kid":"…","kty":"RSA","n":"…","e":"AQAB"}, …]}`.
    /// `nil` disables pinning; discovery is used.
    public let staticJWKSPath: String?

    /// Override URL for the JWKS endpoint.
    ///
    /// When set, the verifier skips discovery and fetches the JWKS
    /// directly from this URL. Useful when an operator fronts the
    /// IdP with an internal mirror whose TLS chain is controlled by
    /// their own PKI — the discovery doc's `jwks_uri` might point at
    /// an external host outside the perimeter, defeating network
    /// segmentation.
    public let jwksURLOverride: String?

    /// Required Authentication Context Class Reference values
    /// (OIDC Core §2, §5.5.1.1, RFC 8176).
    ///
    /// When non-nil and non-empty, the verifier rejects any token
    /// whose `acr` claim is missing or not in this set. This lets
    /// operators require that the IdP performed stepped-up
    /// authentication (MFA, smart card, FIDO2 touch) for the
    /// current token — the OWASP-aligned satisfier of ASVS V2.7
    /// "Out-of-band Verifier" when federated identities drive
    /// privileged actions.
    ///
    /// Typical values:
    ///
    /// - `http://schemas.openid.net/pape/policies/2007/06/multi-factor`
    ///   (legacy OpenID PAPE, still used by some IdPs)
    /// - `http://schemas.openid.net/pape/policies/2007/06/multi-factor-physical`
    ///   (MFA with a physical factor)
    /// - `urn:mace:incommon:iap:silver` (InCommon assurance silver)
    /// - IdP-specific strings: Okta's `phr`/`phrh`, Entra's
    ///   `http://schemas.microsoft.com/claims/multipleauthn`, etc.
    ///
    /// `nil` disables the check — recommended only for service-
    /// account token flows where the IdP's client-credentials
    /// grant semantics make `acr` inapplicable.
    public let requiredACRValues: Swift.Set<String>?

    public init(
        issuerURL: String,
        clientID: String,
        audience: String,
        groupScopeMapping: [String: AuthScope] = [:],
        groupTenantMapping: [String: String] = [:],
        staticJWKSPath: String? = nil,
        jwksURLOverride: String? = nil,
        requiredACRValues: Swift.Set<String>? = nil
    ) {
        self.issuerURL = issuerURL
        self.clientID = clientID
        self.audience = audience
        self.groupScopeMapping = groupScopeMapping
        self.groupTenantMapping = groupTenantMapping
        self.staticJWKSPath = staticJWKSPath
        self.jwksURLOverride = jwksURLOverride
        self.requiredACRValues = requiredACRValues
    }
}
