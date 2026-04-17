import Foundation
import Security
import SpookCore
import SpookApplication

// MARK: - JWT and JWKS schemas

/// The protected header of a JWT.
///
/// Typed decoding replaces `[String: Any]` + `as? String` casts.
/// `kid` is required (we use it to select the verifying key from
/// the JWKS) and `alg` is strictly compared against `"RS256"` —
/// every other algorithm is rejected before we reach the
/// signature-verification step.
struct JWTHeader: Decodable, Sendable {
    let alg: String
    let kid: String
    let typ: String?
}

/// A JWT's `aud` claim, which the JWT spec permits to be either a
/// single string or an array of strings. A custom-decoded enum
/// hides the branching from the validation code above and makes
/// the "missing aud" case a clean failure path.
enum JWTAudience: Sendable {
    case single(String)
    case multiple([String])

    func contains(_ expected: String) -> Bool {
        switch self {
        case .single(let s): s == expected
        case .multiple(let arr): arr.contains(expected)
        }
    }
}

extension JWTAudience: Decodable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) { self = .single(s); return }
        if let a = try? container.decode([String].self) { self = .multiple(a); return }
        throw DecodingError.typeMismatch(
            JWTAudience.self,
            .init(codingPath: decoder.codingPath,
                  debugDescription: "aud must be a string or an array of strings")
        )
    }
}

/// Claims that OIDC / JWT verification reads directly.
///
/// Raw claims beyond this schema are preserved in
/// `FederatedIdentity.claims` via a second pass over the raw
/// JSON — the typed struct is for the validation/extraction path,
/// not the full claim bag.
struct JWTClaims: Decodable, Sendable {
    let iss: String
    let sub: String
    let exp: TimeInterval
    let iat: TimeInterval?
    let nbf: TimeInterval?
    let aud: JWTAudience
    let name: String?
    let preferredUsername: String?
    let email: String?
    let groups: [String]?
    let roles: [String]?
    /// Authentication Context Class Reference (OIDC Core §5.5.1.1).
    /// Values are IdP-defined; we compare against the operator's
    /// `requiredACRValues` allowlist verbatim.
    let acr: String?
    /// Authentication Methods References (RFC 8176). Parsed for
    /// completeness; not currently used for policy decisions but
    /// surfaced in ``FederatedIdentity/claims``.
    let amr: [String]?

    enum CodingKeys: String, CodingKey {
        case iss, sub, exp, iat, nbf, aud, name, email, groups, roles, acr, amr
        case preferredUsername = "preferred_username"
    }
}

/// A single key from a JSON Web Key Set (RFC 7517).
///
/// Only RSA keys (`kty == "RSA"`) are used; `n` and `e` are the
/// base64url-encoded modulus and public exponent. Optional `alg`
/// lets the IdP advertise its signing algorithm, which we still
/// cross-check against the JWT header's `alg` before verification.
struct JWK: Codable, Sendable {
    let kid: String?
    let kty: String?
    let alg: String?
    let use: String?
    let n: String?
    let e: String?
}

/// The JSON Web Key Set document returned by the IdP.
struct JWKSDocument: Codable, Sendable {
    let keys: [JWK]
}

// MARK: - JWKS Cache

/// Cached JSON Web Key Set with a time-to-live.
struct JWKSCache: Sendable {
    let keys: [JWK]
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

        // 2. Decode header via typed struct — kid and alg are
        // required by our validator and the Decodable conformance
        // makes that unambiguous.
        guard let headerData = base64URLDecode(String(parts[0])) else {
            throw OIDCError.malformedToken
        }
        let header: JWTHeader
        do {
            header = try Self.decoder.decode(JWTHeader.self, from: headerData)
        } catch {
            throw OIDCError.malformedToken
        }

        // 3. OWASP: Strictly validate algorithm (prevent none/HS256 confusion)
        // Only RS256 is permitted. Reject ALL other algorithms explicitly.
        // See: https://auth0.com/blog/critical-vulnerabilities-in-json-web-token-libraries/
        let allowedAlgorithms: Swift.Set<String> = ["RS256"]
        guard allowedAlgorithms.contains(header.alg) else {
            throw OIDCError.unsupportedAlgorithm(header.alg)
        }

        // 4. **iss-before-key** — decode the payload WITHOUT
        // signature verification, read `iss`, reject on
        // mismatch, THEN verify the signature against the key
        // set selected by iss.
        //
        // Without this step, a token signed by IdP-A but carrying
        // `iss = IdP-B` in its payload could verify against
        // IdP-A's keyset (the signature is valid, the alg matches)
        // and the downstream authorization layer would then trust
        // it as an IdP-B-issued identity. Classic cross-IdP
        // confusion — defended here by **gating the JWKS lookup
        // on the configured issuer first**.
        //
        // We do the unverified decode in a local do/catch so a
        // malformed payload surfaces as `malformedToken`, never
        // an optional-fallthrough into the authenticated path.
        guard let payloadData = base64URLDecode(String(parts[1])) else {
            throw OIDCError.malformedToken
        }
        let claims: JWTClaims
        do {
            claims = try Self.decoder.decode(JWTClaims.self, from: payloadData)
        } catch {
            if case let DecodingError.keyNotFound(key, _)? = error as? DecodingError {
                throw OIDCError.missingRequiredClaim(key.stringValue)
            }
            throw OIDCError.malformedToken
        }

        // Pre-signature issuer gate. A mismatched `iss` short-
        // circuits before we even consult the JWKS for `config.issuerURL`.
        guard claims.iss == config.issuerURL else {
            throw OIDCError.issuerMismatch
        }

        // 5. Fetch the JWKS **for our configured issuer** and
        // select a key by kid. Because step 4 already rejected
        // a mismatched `iss`, the JWKS we select here is always
        // the one matching the claimed issuer.
        let keys = try await getJWKS()
        guard let matchingKey = keys.first(where: { $0.kid == header.kid }) else {
            throw OIDCError.signatureVerificationFailed
        }

        let signedInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard let signatureData = base64URLDecode(String(parts[2])) else {
            throw OIDCError.malformedToken
        }

        try verifyRS256(signedInput: signedInput, signature: signatureData, jwk: matchingKey)

        // 6. Validate audience. `config.audience` is now
        // non-optional (see `OIDCProviderConfig.audience`): the
        // old `?? clientID` fallback invited cross-client
        // confusion on shared-issuer IdPs. OIDC Core §3.1.3.7
        // requires audience validation.
        guard claims.aud.contains(config.audience) else {
            throw OIDCError.audienceMismatch
        }

        // 7. Validate temporal claims: exp (required), iat, nbf.
        // `exp` is required by the type; iat / nbf are optional.
        // 60s skew applies symmetrically to all three.
        let exp = Date(timeIntervalSince1970: claims.exp)
        let clockSkew: TimeInterval = 60
        let now = Date()
        guard now < exp.addingTimeInterval(clockSkew) else {
            throw OIDCError.tokenExpired
        }
        if let iatTimestamp = claims.iat {
            let iat = Date(timeIntervalSince1970: iatTimestamp)
            guard iat < now.addingTimeInterval(clockSkew) else {
                throw OIDCError.tokenIssuedInFuture
            }
        }
        if let nbfTimestamp = claims.nbf {
            let nbf = Date(timeIntervalSince1970: nbfTimestamp)
            guard now >= nbf.addingTimeInterval(-clockSkew) else {
                throw OIDCError.tokenNotYetValid
            }
        }

        // 8a. Enforce Authentication Context Class Reference
        // (OIDC Core §5.5.1.1, OWASP ASVS V2.7 / V4.3.1). When the
        // operator configured `requiredACRValues`, the IdP-provided
        // `acr` claim must be present and in the allowlist — the
        // stepped-up authentication gate for privileged tokens.
        if let required = config.requiredACRValues, !required.isEmpty {
            guard let acr = claims.acr, required.contains(acr) else {
                throw OIDCError.insufficientACR(
                    required: required, received: claims.acr
                )
            }
        }

        // 9. Extract identity. Empty `sub` was previously accepted;
        // the typed struct now treats absent `sub` as a decode error
        // (handled above) and we reject an empty string here.
        guard !claims.sub.isEmpty else {
            throw OIDCError.missingRequiredClaim("sub")
        }
        let displayName = claims.name ?? claims.preferredUsername
        let groups = claims.groups ?? claims.roles ?? []

        // 10. Preserve the raw string-valued claims for consumers
        // that inspect `FederatedIdentity.claims`. The typed struct
        // above covers the validation-relevant claims; anything
        // else the IdP shipped gets carried through.
        let stringClaims = Self.extractStringClaims(from: payloadData)

        return FederatedIdentity(
            issuer: claims.iss, subject: claims.sub, displayName: displayName,
            email: claims.email, groups: groups, expiresAt: exp,
            claims: stringClaims
        )
    }

    // Shared across every verify() call, no per-request allocation.
    private static let decoder = JSONDecoder()

    /// Extracts all top-level string-valued claims from a JWT
    /// payload for pass-through to `FederatedIdentity.claims`.
    ///
    /// Kept as a second JSON decode instead of baking it into
    /// `JWTClaims` because claim names vary wildly across IdPs
    /// (Azure AD alone adds ~30 claim keys) and a typed mapping
    /// would either be incomplete or enormous.
    private static func extractStringClaims(from data: Data) -> [String: String] {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict.compactMapValues { $0 as? String }
    }

    // MARK: - JWKS Fetching

    /// Returns the cached JWKS keys, refreshing from the provider if expired or absent.
    private func getJWKS() async throws -> [JWK] {
        if let cache = jwksCache, !cache.isExpired {
            return cache.keys
        }
        let keys = try await fetchJWKS()
        jwksCache = JWKSCache(keys: keys, fetchedAt: Date(), ttl: 3600)
        return keys
    }

    /// Fetches (or loads) the provider's JWKS using — in priority
    /// order — the pinned static file, the configured URL override,
    /// or OpenID Connect discovery.
    ///
    /// ## Resolution order
    ///
    /// 1. `config.staticJWKSPath` — load JWKS from disk. The
    ///    strongest defense against a network attacker: the keys
    ///    are at rest on the host, signed into config management,
    ///    and never touch the wire at verification time.
    /// 2. `config.jwksURLOverride` — fetch directly from the given
    ///    URL, skipping discovery. For operators mirroring an IdP
    ///    through their own PKI.
    /// 3. Discovery fallback — `{issuer}/.well-known/openid-configuration`
    ///    → `jwks_uri` → GET. The original behavior; still correct
    ///    when the IdP and the verifier are on the same trusted
    ///    network segment.
    private func fetchJWKS() async throws -> [JWK] {
        // Tier 1: static file — bypass the network entirely.
        if let path = config.staticJWKSPath {
            guard let data = try? Data(contentsOf: URL(filePath: path)),
                  let doc = try? Self.decoder.decode(JWKSDocument.self, from: data) else {
                throw OIDCError.staticJWKSUnreadable(path: path)
            }
            return doc.keys
        }

        // Tier 2: explicit URL override — skip discovery, fetch directly.
        if let override = config.jwksURLOverride,
           let jwksURL = URL(string: override) {
            let response = try await http.execute(DomainHTTPRequest(method: .get, url: jwksURL))
            guard let doc = try? Self.decoder.decode(JWKSDocument.self, from: response.body) else {
                throw OIDCError.jwksFetchFailed
            }
            return doc.keys
        }

        // Tier 3: discovery fallback.
        struct Discovery: Decodable { let jwks_uri: String }
        let configURL = URL(string: "\(config.issuerURL)/.well-known/openid-configuration")!
        let configResponse = try await http.execute(DomainHTTPRequest(method: .get, url: configURL))
        guard let discovery = try? Self.decoder.decode(Discovery.self, from: configResponse.body),
              let jwksURL = URL(string: discovery.jwks_uri) else {
            throw OIDCError.jwksFetchFailed
        }
        let jwksResponse = try await http.execute(DomainHTTPRequest(method: .get, url: jwksURL))
        guard let doc = try? Self.decoder.decode(JWKSDocument.self, from: jwksResponse.body) else {
            throw OIDCError.jwksFetchFailed
        }
        return doc.keys
    }

    // MARK: - Signature Verification

    /// Verifies an RS256 (RSASSA-PKCS1-v1_5 with SHA-256) signature using Security.framework.
    private func verifyRS256(signedInput: Data, signature: Data, jwk: JWK) throws {
        guard let nB64 = jwk.n, let eB64 = jwk.e,
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

        // Enforce NIST SP 800-131A Rev 2 minimum RSA key size (2048).
        // RSA-1024 is disallowed post-2015; `SecKeyCreateWithData`
        // will parse a 1024-bit key without complaint and
        // `SecKeyVerifySignature` will accept its signatures, so the
        // check has to be explicit.
        let keyBits = SecKeyGetBlockSize(publicKey) * 8
        guard keyBits >= 2048 else {
            throw OIDCError.weakKey(bits: keyBits)
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
            // Guard against an empty modulus/exponent. A rogue or
            // MITM-altered JWKS can send "n":"" or "e":""; the old
            // `d.first!` force-unwrap crashed the entire verifier
            // (DoS). Empty data is never a valid DER INTEGER.
            guard let firstByte = d.first else {
                return Data([0x02, 0x01, 0x00])   // encode INTEGER 0
            }
            if firstByte >= 0x80 { d.insert(0x00, at: 0) } // prepend zero for positive
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

    /// The `nbf` (not-before) claim is in the future beyond the
    /// 60 s skew tolerance. The token is pre-activation and MUST
    /// be rejected per RFC 7519 §4.1.5.
    case tokenNotYetValid

    /// The presented RSA key is smaller than NIST SP 800-131A's
    /// 2048-bit minimum. Associated value is the observed key size.
    case weakKey(bits: Int)
    /// The token's `aud` claim does not match the configured client.
    case audienceMismatch
    /// The token's `exp` claim is in the past.
    case tokenExpired
    /// Failed to fetch the provider's JWKS endpoint.
    case jwksFetchFailed
    /// The pinned static JWKS file is missing, unreadable, or malformed.
    case staticJWKSUnreadable(path: String)
    /// JWT signature verification failed against provider's JWKS.
    case signatureVerificationFailed
    /// JWT uses an unsupported or dangerous algorithm (e.g., none, HS256).
    case unsupportedAlgorithm(String)

    /// The token's `acr` claim is missing or does not match any
    /// of the operator-required values. Satisfies OWASP ASVS
    /// V2.7 / V4.3.1 — the stepped-up-MFA gate for federated
    /// privileged tokens.
    case insufficientACR(required: Swift.Set<String>, received: String?)

    public var errorDescription: String? {
        switch self {
        case .malformedToken: "Malformed JWT token"
        case .issuerMismatch: "Token issuer does not match configured provider"
        case .missingRequiredClaim(let claim): "Token is missing required claim '\(claim)'"
        case .tokenIssuedInFuture: "Token iat is in the future beyond clock-skew tolerance"
        case .tokenNotYetValid: "Token nbf is in the future beyond clock-skew tolerance"
        case .weakKey(let bits): "IdP RSA key is \(bits) bits; minimum is 2048 per NIST SP 800-131A"
        case .audienceMismatch: "Token audience does not match configured client"
        case .tokenExpired: "Token has expired"
        case .jwksFetchFailed: "Failed to fetch JWKS from identity provider"
        case .staticJWKSUnreadable(let path):
            "Pinned JWKS at '\(path)' is missing, unreadable, or not a valid JWKS JSON document"
        case .signatureVerificationFailed: "JWT signature verification failed against provider's JWKS"
        case .unsupportedAlgorithm(let alg): "JWT uses unsupported algorithm '\(alg)'. Only RS256 is permitted."
        case .insufficientACR(let required, let received):
            "Token acr=\(received ?? "(missing)") did not match any required value (\(required.sorted().joined(separator: ", ")))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .malformedToken:
            "The bearer isn't a valid three-part base64url JWT. If a client is generating tokens, make sure each segment is base64url-encoded and that the header uses `{\"alg\":\"RS256\",\"kid\":\"...\"}`."
        case .issuerMismatch:
            "Confirm `OIDCProviderConfig.issuerURL` matches the `iss` claim the IdP emits. The string must match exactly — trailing slashes, scheme case, and port all count."
        case .missingRequiredClaim(let claim):
            "The IdP must include `\(claim)` on every token. If this is an Azure AD configuration, review the access-token claims mapping in the app registration."
        case .tokenIssuedInFuture:
            "Clock skew between the IdP and this host is > 60s. Enable NTP on this host (`sudo sntp -sS time.apple.com`) or adjust the IdP's clock."
        case .tokenNotYetValid:
            "Token has an `nbf` in the future — the IdP schedules pre-activation tokens. Caller should wait until nbf passes; check for systemic clock skew if persistent."
        case .weakKey(let bits):
            "The IdP's RSA key is \(bits) bits, below the NIST SP 800-131A minimum of 2048. Ask the IdP operator to rotate to a 2048-bit or larger key; RSA-1024 has been disallowed since 2015."
        case .audienceMismatch:
            "Token `aud` didn't match. Check `OIDCProviderConfig.audience` — or `clientID` when audience is nil — against the `aud` the IdP emits for this client."
        case .tokenExpired:
            "The token's `exp` has passed. Caller should re-authenticate to obtain a fresh token."
        case .jwksFetchFailed:
            "Could not fetch JWKS from the IdP. Verify network reachability to the configured `issuerURL`, or set `OIDCProviderConfig.staticJWKSPath` to pin a local JWKS document."
        case .staticJWKSUnreadable(let path):
            "Ensure `\(path)` exists, is readable by the daemon user, and contains a JWKS document: `{\"keys\":[{\"kid\":\"...\",\"kty\":\"RSA\",\"n\":\"...\",\"e\":\"AQAB\"}]}`."
        case .signatureVerificationFailed:
            "Signature did not verify. Usually means a kid mismatch (the JWKS doesn't have the key that signed the token — cache TTL may be too long) or a tampered token."
        case .unsupportedAlgorithm:
            "Only RS256 is accepted — an IdP emitting HS256/none/ES256 either points at the wrong service or is vulnerable to algorithm-confusion attacks. Do not relax this check."
        case .insufficientACR:
            "The IdP-emitted `acr` did not prove stepped-up authentication. Configure the IdP to require MFA on the relevant scope, or broaden `OIDCProviderConfig.requiredACRValues` to include the value the IdP actually emits."
        }
    }
}
