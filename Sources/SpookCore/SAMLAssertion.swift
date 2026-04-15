import Foundation

/// A verified identity from a SAML assertion.
///
/// Extracted from a SAML Response after signature verification.
/// Maps to the same FederatedIdentity model for unified authorization.
public struct SAMLAssertion: Sendable, Codable {
    /// The SAML IdP entity ID (e.g., "https://idp.example.com/saml")
    public let issuer: String
    /// The NameID from the SAML assertion (unique user identifier)
    public let nameID: String
    /// The NameID format (e.g., "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress")
    public let nameIDFormat: String?
    /// Session expiry from SessionNotOnOrAfter
    public let sessionExpiresAt: Date?
    /// Attributes extracted from the assertion (groups, roles, email, etc.)
    public let attributes: [String: [String]]

    public init(issuer: String, nameID: String, nameIDFormat: String? = nil,
                sessionExpiresAt: Date? = nil, attributes: [String: [String]] = [:]) {
        self.issuer = issuer
        self.nameID = nameID
        self.nameIDFormat = nameIDFormat
        self.sessionExpiresAt = sessionExpiresAt
        self.attributes = attributes
    }

    /// Converts to a FederatedIdentity for unified authorization.
    public func toFederatedIdentity() -> FederatedIdentity {
        let groups = attributes["groups"] ?? attributes["role"] ?? attributes["memberOf"] ?? []
        let email = attributes["email"]?.first ?? (nameIDFormat?.contains("emailAddress") == true ? nameID : nil)
        return FederatedIdentity(
            issuer: issuer,
            subject: nameID,
            displayName: attributes["displayName"]?.first,
            email: email,
            groups: groups,
            expiresAt: sessionExpiresAt,
            claims: attributes.mapValues { $0.joined(separator: ",") }
        )
    }

    public var isExpired: Bool {
        guard let exp = sessionExpiresAt else { return false }
        return Date() > exp
    }
}

/// Configuration for a SAML identity provider.
public struct SAMLProviderConfig: Sendable, Codable {
    /// The IdP's entity ID
    public let entityID: String
    /// The IdP's SSO URL
    public let ssoURL: String
    /// Base64-encoded X.509 certificate for signature verification
    public let certificate: String
    /// Map SAML groups/roles to Spooktacular scopes
    public let groupScopeMapping: [String: AuthScope]
    /// Map SAML groups/roles to tenant IDs
    public let groupTenantMapping: [String: String]

    public init(entityID: String, ssoURL: String, certificate: String,
                groupScopeMapping: [String: AuthScope] = [:],
                groupTenantMapping: [String: String] = [:]) {
        self.entityID = entityID
        self.ssoURL = ssoURL
        self.certificate = certificate
        self.groupScopeMapping = groupScopeMapping
        self.groupTenantMapping = groupTenantMapping
    }
}
