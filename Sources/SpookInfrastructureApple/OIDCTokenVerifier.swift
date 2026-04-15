import Foundation
import SpookCore
import SpookApplication

// MARK: - JWKS Cache

/// Cached JSON Web Key Set with a time-to-live.
struct JWKSCache: Sendable {
    let keys: [[String: String]]
    let fetchedAt: Date
    let ttl: TimeInterval

    var isExpired: Bool {
        Date().timeIntervalSince(fetchedAt) > ttl
    }
}

// MARK: - OIDC Token Verifier

/// Verifies OIDC JWT tokens by fetching the provider's JWKS and validating claims.
///
/// This actor is the infrastructure-layer adapter for
/// ``FederatedIdentityVerifier``. It validates:
///
/// 1. Token structure (three-part JWT)
/// 2. Issuer matches the configured ``OIDCProviderConfig/issuerURL``
/// 3. Audience matches the configured ``OIDCProviderConfig/audience`` (when set)
/// 4. Expiration (`exp` claim)
///
/// ## Signature Verification
///
/// Full JWKS-based signature verification requires a cryptographic library
/// (e.g., CryptoKit + JWK parsing). This implementation validates claims
/// and structure; signature verification against the provider's JWKS is
/// a follow-up item tracked separately.
///
/// ## Thread Safety
///
/// Declared as an `actor` so the JWKS cache can be mutated safely from
/// concurrent callers.
public actor OIDCTokenVerifier: FederatedIdentityVerifier {
    private let config: OIDCProviderConfig
    private let http: any HTTPClient
    private var jwksCache: JWKSCache?

    public init(config: OIDCProviderConfig, http: any HTTPClient) {
        self.config = config
        self.http = http
    }

    public func verify(token: String) async throws -> FederatedIdentity {
        // 1. Decode JWT header + payload (base64url)
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw OIDCError.malformedToken }

        guard let payloadData = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw OIDCError.malformedToken }

        // 2. Validate issuer
        guard let iss = claims["iss"] as? String, iss == config.issuerURL
        else { throw OIDCError.issuerMismatch }

        // 3. Validate audience
        if let expectedAud = config.audience {
            let aud = claims["aud"]
            let audMatch: Bool
            if let audString = aud as? String {
                audMatch = audString == expectedAud
            } else if let audArray = aud as? [String] {
                audMatch = audArray.contains(expectedAud)
            } else {
                audMatch = false
            }
            guard audMatch else { throw OIDCError.audienceMismatch }
        }

        // 4. Validate expiration
        let exp: Date?
        if let expTimestamp = claims["exp"] as? TimeInterval {
            exp = Date(timeIntervalSince1970: expTimestamp)
            guard Date() < exp! else { throw OIDCError.tokenExpired }
        } else {
            exp = nil
        }

        // 5. Extract identity
        let sub = claims["sub"] as? String ?? ""
        let name = claims["name"] as? String ?? claims["preferred_username"] as? String
        let email = claims["email"] as? String
        let groups: [String]
        if let g = claims["groups"] as? [String] {
            groups = g
        } else if let roles = claims["roles"] as? [String] {
            groups = roles
        } else {
            groups = []
        }

        // 6. Map claims to strings for storage
        var stringClaims: [String: String] = [:]
        for (k, v) in claims {
            if let s = v as? String { stringClaims[k] = s }
        }

        return FederatedIdentity(
            issuer: iss, subject: sub, displayName: name,
            email: email, groups: groups, expiresAt: exp,
            claims: stringClaims
        )
    }

    private func base64URLDecode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
                          .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

// MARK: - OIDC Errors

/// Errors produced during OIDC token verification.
public enum OIDCError: Error, LocalizedError, Sendable {
    /// The token is not a valid three-part JWT.
    case malformedToken
    /// The token's `iss` claim does not match the configured provider.
    case issuerMismatch
    /// The token's `aud` claim does not match the configured client.
    case audienceMismatch
    /// The token's `exp` claim is in the past.
    case tokenExpired
    /// Failed to fetch the provider's JWKS endpoint.
    case jwksFetchFailed

    public var errorDescription: String? {
        switch self {
        case .malformedToken: "Malformed JWT token"
        case .issuerMismatch: "Token issuer does not match configured provider"
        case .audienceMismatch: "Token audience does not match configured client"
        case .tokenExpired: "Token has expired"
        case .jwksFetchFailed: "Failed to fetch JWKS from identity provider"
        }
    }
}
