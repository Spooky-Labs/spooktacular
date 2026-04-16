import Foundation
import Security
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
/// 2. Cryptographic signature against the provider's JWKS
/// 3. Issuer matches the configured ``OIDCProviderConfig/issuerURL``
/// 4. Audience matches the configured ``OIDCProviderConfig/audience`` (when set)
/// 5. Expiration (`exp` claim)
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
        // 1. OWASP: Reject excessively long tokens to prevent memory exhaustion
        guard token.count < 16_384 else { throw OIDCError.malformedToken }

        // Split JWT into three parts
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw OIDCError.malformedToken }

        // Reject segments over 10 KB each
        for part in parts {
            guard part.count < 10_240 else { throw OIDCError.malformedToken }
        }

        // 2. Decode header to extract kid and alg
        guard let headerData = base64URLDecode(String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let kid = header["kid"] as? String,
              let alg = header["alg"] as? String else {
            throw OIDCError.malformedToken
        }

        // 3. OWASP: Strictly validate algorithm (prevent none/HS256 confusion)
        // Only RS256 is permitted. Reject ALL other algorithms explicitly.
        // See: https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/
        let allowedAlgorithms: Swift.Set<String> = ["RS256"]
        guard allowedAlgorithms.contains(alg) else {
            throw OIDCError.unsupportedAlgorithm(alg)
        }

        // 4. Verify cryptographic signature against JWKS
        let keys = try await getJWKS()
        guard let matchingKey = keys.first(where: { $0["kid"] as? String == kid }) else {
            throw OIDCError.signatureVerificationFailed
        }

        let signedInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard let signatureData = base64URLDecode(String(parts[2])) else {
            throw OIDCError.malformedToken
        }

        try verifyRS256(signedInput: signedInput, signature: signatureData, jwk: matchingKey)

        // 4. Decode payload
        guard let payloadData = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else { throw OIDCError.malformedToken }

        // 5. Validate issuer
        guard let iss = claims["iss"] as? String, iss == config.issuerURL
        else { throw OIDCError.issuerMismatch }

        // 6. Validate audience
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

        // 7. Validate expiration.
        //
        // OIDC Core §2 requires `exp`. An IdP that omits it MUST be
        // rejected — a token "that never expires" is an unbounded
        // credential. 60s of clock skew is the RFC 7519 §4.1.4
        // recommendation; any larger window would create a window
        // where expired tokens still authenticate.
        guard let expTimestamp = claims["exp"] as? TimeInterval else {
            throw OIDCError.missingRequiredClaim("exp")
        }
        let exp = Date(timeIntervalSince1970: expTimestamp)
        let clockSkew: TimeInterval = 60
        guard Date() < exp.addingTimeInterval(clockSkew) else {
            throw OIDCError.tokenExpired
        }

        // Also reject tokens issued in the future beyond skew
        // tolerance — that catches clock-manipulation attacks.
        if let iatTimestamp = claims["iat"] as? TimeInterval {
            let iat = Date(timeIntervalSince1970: iatTimestamp)
            guard iat < Date().addingTimeInterval(clockSkew) else {
                throw OIDCError.tokenIssuedInFuture
            }
        }

        // 8. Extract identity. OIDC Core §5.1 requires `sub`. An
        // empty string was previously accepted — that collapses all
        // tokens without a subject to the same anonymous principal.
        guard let sub = claims["sub"] as? String, !sub.isEmpty else {
            throw OIDCError.missingRequiredClaim("sub")
        }
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

        // 9. Map claims to strings for storage
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

    // MARK: - JWKS Fetching

    /// Returns the cached JWKS keys, refreshing from the provider if expired or absent.
    private func getJWKS() async throws -> [[String: Any]] {
        if let cache = jwksCache, !cache.isExpired {
            // Convert cached [String: String] to [String: Any] for compatibility
            return cache.keys.map { $0 as [String: Any] }
        }
        let keys = try await fetchJWKS()
        // Store as [String: String] for Sendable conformance in the cache
        let stringKeys: [[String: String]] = keys.map { dict in
            var result: [String: String] = [:]
            for (k, v) in dict {
                if let s = v as? String { result[k] = s }
            }
            return result
        }
        jwksCache = JWKSCache(keys: stringKeys, fetchedAt: Date(), ttl: 3600)
        return keys
    }

    /// Fetches the provider's JWKS by first reading the OpenID Connect discovery document.
    private func fetchJWKS() async throws -> [[String: Any]] {
        // 1. Fetch .well-known/openid-configuration
        let configURL = URL(string: "\(config.issuerURL)/.well-known/openid-configuration")!
        let configResponse = try await http.execute(DomainHTTPRequest(method: .get, url: configURL))
        guard let configJSON = try? JSONSerialization.jsonObject(with: configResponse.body) as? [String: Any],
              let jwksURI = configJSON["jwks_uri"] as? String,
              let jwksURL = URL(string: jwksURI) else {
            throw OIDCError.jwksFetchFailed
        }

        // 2. Fetch JWKS
        let jwksResponse = try await http.execute(DomainHTTPRequest(method: .get, url: jwksURL))
        guard let jwksJSON = try? JSONSerialization.jsonObject(with: jwksResponse.body) as? [String: Any],
              let keys = jwksJSON["keys"] as? [[String: Any]] else {
            throw OIDCError.jwksFetchFailed
        }
        return keys
    }

    // MARK: - Signature Verification

    /// Verifies an RS256 (RSASSA-PKCS1-v1_5 with SHA-256) signature using Security.framework.
    private func verifyRS256(signedInput: Data, signature: Data, jwk: [String: Any]) throws {
        guard let nB64 = jwk["n"] as? String, let eB64 = jwk["e"] as? String,
              let n = base64URLDecode(nB64), let e = base64URLDecode(eB64) else {
            throw OIDCError.signatureVerificationFailed
        }

        // Build DER-encoded RSA public key from n and e
        let publicKeyData = buildRSAPublicKeyDER(modulus: n, exponent: e)

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(publicKeyData as CFData, attributes as CFDictionary, &error) else {
            throw OIDCError.signatureVerificationFailed
        }

        guard SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, signedInput as CFData, signature as CFData, &error) else {
            throw OIDCError.signatureVerificationFailed
        }
    }

    /// Constructs a DER-encoded RSA public key from raw modulus and exponent bytes.
    private func buildRSAPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        // ASN.1 DER encoding helpers
        func lengthBytes(_ length: Int) -> Data {
            if length < 128 { return Data([UInt8(length)]) }
            if length < 256 { return Data([0x81, UInt8(length)]) }
            return Data([0x82, UInt8(length >> 8), UInt8(length & 0xFF)])
        }
        func integer(_ data: Data) -> Data {
            var d = data
            if d.first! >= 0x80 { d.insert(0x00, at: 0) } // prepend zero for positive
            return Data([0x02]) + lengthBytes(d.count) + d
        }
        let modInt = integer(modulus)
        let expInt = integer(exponent)
        let seq = modInt + expInt
        let innerSeq = Data([0x30]) + lengthBytes(seq.count) + seq
        let bitString = Data([0x03]) + lengthBytes(innerSeq.count + 1) + Data([0x00]) + innerSeq
        // RSA algorithm OID: 1.2.840.113549.1.1.1 with NULL parameters
        let algOID = Data([0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00])
        let outer = algOID + bitString
        return Data([0x30]) + lengthBytes(outer.count) + outer
    }

    // MARK: - Base64URL

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

    /// A required OIDC claim (e.g. `exp`, `sub`) was absent.
    case missingRequiredClaim(String)

    /// The `iat` claim is in the future beyond the 60 s skew
    /// tolerance. Indicates a clock-skew or replay attack.
    case tokenIssuedInFuture
    /// The token's `aud` claim does not match the configured client.
    case audienceMismatch
    /// The token's `exp` claim is in the past.
    case tokenExpired
    /// Failed to fetch the provider's JWKS endpoint.
    case jwksFetchFailed
    /// JWT signature verification failed against provider's JWKS.
    case signatureVerificationFailed
    /// JWT uses an unsupported or dangerous algorithm (e.g., none, HS256).
    case unsupportedAlgorithm(String)

    public var errorDescription: String? {
        switch self {
        case .malformedToken: "Malformed JWT token"
        case .issuerMismatch: "Token issuer does not match configured provider"
        case .missingRequiredClaim(let claim): "Token is missing required claim '\(claim)'"
        case .tokenIssuedInFuture: "Token iat is in the future beyond clock-skew tolerance"
        case .audienceMismatch: "Token audience does not match configured client"
        case .tokenExpired: "Token has expired"
        case .jwksFetchFailed: "Failed to fetch JWKS from identity provider"
        case .signatureVerificationFailed: "JWT signature verification failed against provider's JWKS"
        case .unsupportedAlgorithm(let alg): "JWT uses unsupported algorithm '\(alg)'. Only RS256 is permitted."
        }
    }
}
