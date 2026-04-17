import Foundation
import CryptoKit
import SpookCore

/// Mints short-lived OIDC-compatible ES256 JWTs that attest the
/// identity of a Spooktacular-managed VM (or other workload).
///
/// ## Why this exists
///
/// AWS, GCP, and Azure all accept customer-configured OIDC
/// providers for workload identity federation. A VM running a
/// CI job (or any workload) presents the JWT to
/// `sts:AssumeRoleWithWebIdentity` (or its equivalent) and
/// receives short-lived cloud credentials scoped to the IAM role
/// the operator bound to that VM — no long-lived access keys,
/// no shared secrets in VM images.
///
/// ## Why ES256 (not RS256)
///
/// AWS IAM OIDC providers accept `RS256, RS384, RS512, ES256,
/// ES384, ES512` (per the [IAM prerequisites docs]). ES256 is
/// P-256 ECDSA with SHA-256 (RFC 7518 §3.4) — the same primitive
/// the macOS Secure Enclave supports natively. Using ES256 lets
/// the issuing key live **inside the SEP** and never touch
/// process memory, which is a materially stronger non-
/// repudiation story than any software-keyed JWT issuer.
///
/// ## Signature format gotcha
///
/// RFC 7518 §3.4 specifies the JWS signature is the raw 64-byte
/// `r ‖ s` concatenation, *not* the DER-encoded ASN.1 sequence
/// that some libraries emit. CryptoKit's
/// `P256.Signing.ECDSASignature.rawRepresentation` is already
/// the raw form, so signing via ``P256Signer/signature(for:)``
/// (which returns `rawRepresentation` per the protocol) produces
/// a JWT verifier-compatible signature directly. This is the
/// most common ES256 JWT implementation bug; we avoid it by
/// construction.
///
/// ## Key rotation
///
/// `WorkloadTokenIssuer` is immutable — to rotate signing keys,
/// assemble an ``IssuerKeySet`` with the new "current" key plus
/// the old key as "previous" and create a fresh issuer. The JWKS
/// endpoint serves both keys for a 24-hour overlap so in-flight
/// JWTs signed by the previous key still verify while the
/// current key takes over new mints. See
/// `Docs/runbooks/workload-key-rotation.md` for the operator
/// procedure.
///
/// [IAM prerequisites docs]: https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html
public struct WorkloadTokenIssuer: Sendable {

    /// The `iss` claim — must match the URL the cloud provider
    /// has registered as the OIDC provider URL.
    public let issuerURL: String

    /// The signing-key set. Always contains a `current` key and
    /// optionally a `previous` key during the rotation overlap.
    public let keys: IssuerKeySet

    /// Stable key ID of the *current* key. Tokens minted today
    /// carry this `kid` in their header; verifiers pair it with
    /// the `current` JWK the JWKS endpoint serves.
    public var kid: String { keys.current.kid }

    /// Default token TTL (15 minutes). STS credentials derived
    /// from the token have their own TTL (up to the role's
    /// MaxSessionDuration), so a short JWT lifetime is safe:
    /// STS consumes the JWT once and the caller holds the
    /// longer-lived STS credentials thereafter.
    public static let defaultTokenTTL: TimeInterval = 900

    /// The overlap window during which a previous key is still
    /// published via JWKS. 24 hours gives downstream verifiers a
    /// full day to pick up the new JWKS before old-key-signed
    /// tokens become unverifiable — comfortably beyond AWS IAM's
    /// typical JWKS refresh interval.
    public static let defaultRotationOverlap: TimeInterval = 24 * 60 * 60

    /// Primary constructor — caller supplies a pre-assembled key set.
    public init(issuerURL: String, keys: IssuerKeySet) {
        self.issuerURL = issuerURL
        self.keys = keys
    }

    /// Single-key convenience initializer. Equivalent to calling
    /// ``init(issuerURL:keys:)`` with ``IssuerKeySet/single(_:)``.
    public init(issuerURL: String, signer: any P256Signer) {
        self.init(issuerURL: issuerURL, keys: .single(signer))
    }

    // MARK: - Token issuance

    /// Mints an ES256 JWT that attests the given workload
    /// identity. Caller supplies the `sub`, the target audience
    /// (e.g., `"sts.amazonaws.com"`), and optional custom
    /// claims (e.g., VM name, runner labels).
    public func mintToken(
        subject: String,
        audience: String,
        tenant: TenantID? = nil,
        additionalClaims: [String: String] = [:],
        ttl: TimeInterval = defaultTokenTTL,
        now: Date = Date()
    ) throws -> String {
        let exp = now.addingTimeInterval(ttl)
        let jti = UUID().uuidString

        // Header — note no `x5c` / `x5t` since we publish the
        // key via JWKS. `typ: "JWT"` is informational only but
        // required by some strict verifiers. Always use the
        // *current* key's `kid`; the `previous` key is only
        // published for verification.
        let header: [String: String] = [
            "alg": "ES256",
            "kid": keys.current.kid,
            "typ": "JWT"
        ]

        // Claims — standard OIDC plus Spooktacular-specific
        // `tenant`. IAM trust policies can key off any of these
        // via `StringEquals`/`StringLike` conditions.
        var claims: [String: Any] = [
            "iss": issuerURL,
            "sub": subject,
            "aud": audience,
            "iat": Int(now.timeIntervalSince1970),
            "nbf": Int(now.timeIntervalSince1970),
            "exp": Int(exp.timeIntervalSince1970),
            "jti": jti
        ]
        if let tenant {
            claims["tenant"] = tenant.rawValue
        }
        for (k, v) in additionalClaims {
            claims[k] = v
        }

        let headerJSON = try stableJSON(header as [String: Any])
        let claimsJSON = try stableJSON(claims)

        let encodedHeader = Self.base64URL(headerJSON)
        let encodedClaims = Self.base64URL(claimsJSON)
        let signingInput = "\(encodedHeader).\(encodedClaims)"

        // Signer returns raw r ‖ s (64 bytes). Perfect for ES256
        // — NO DER stripping needed because our P256Signer
        // protocol is already raw-form.
        let signature = try keys.current.signer.signature(for: Data(signingInput.utf8))
        let encodedSignature = Self.base64URL(signature)

        return "\(signingInput).\(encodedSignature)"
    }

    // MARK: - JWKS

    /// Returns the JWKS document that `.well-known/jwks.json`
    /// serves. During a rotation window this contains both the
    /// current and previous keys — verifiers still holding a
    /// stale JWKS cache continue to validate recently-minted
    /// previous-key tokens.
    public func jwks() -> JWKSDocument {
        var list = [jwk(for: keys.current)]
        if let prev = keys.previous {
            list.append(jwk(for: prev))
        }
        return JWKSDocument(keys: list)
    }

    /// Returns this issuer's current JWK. Retained for binary
    /// compatibility with the pre-rotation `single-key` tests.
    public func jwk() -> JWK {
        jwk(for: keys.current)
    }

    /// Returns the minimal OIDC discovery document. Fields
    /// match AWS IAM OIDC provider's required `openid-configuration`
    /// prerequisites — missing any of these causes
    /// `CreateOpenIDConnectProvider` / `AssumeRoleWithWebIdentity`
    /// to fail.
    public func discovery() -> OIDCDiscoveryDocument {
        OIDCDiscoveryDocument(
            issuer: issuerURL,
            jwksURI: "\(issuerURL.trimmingTrailingSlash)/.well-known/jwks.json",
            responseTypesSupported: ["id_token"],
            subjectTypesSupported: ["public"],
            idTokenSigningAlgValuesSupported: ["ES256"],
            claimsSupported: ["iss", "sub", "aud", "iat", "exp", "nbf", "jti", "tenant"]
        )
    }

    // MARK: - Rotation

    /// Promotes the `newCurrent` key to `current` and demotes the
    /// existing `current` to `previous`, discarding any key that
    /// was previously in the `previous` slot.
    ///
    /// This is the functional, immutable rotation primitive the
    /// operator runbook calls: copy the existing issuer, call
    /// `rotated(to: newKey)`, then atomically swap the issuer in
    /// the control-plane's DI container. In-flight JWTs signed by
    /// the now-previous key continue to verify via JWKS for the
    /// default ``defaultRotationOverlap`` window.
    public func rotated(to newCurrent: any P256Signer) -> WorkloadTokenIssuer {
        let newCurrentKey = IssuerKey(signer: newCurrent)
        let set = IssuerKeySet(current: newCurrentKey, previous: keys.current)
        return WorkloadTokenIssuer(issuerURL: issuerURL, keys: set)
    }

    // MARK: - Helpers

    /// Derives a stable, short key ID from the public key
    /// fingerprint. 16 hex chars is plenty to disambiguate
    /// keys in a rotation window (collision probability is
    /// negligible at <1000 keys).
    public static func deriveKID(from publicKey: P256.Signing.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKey.x963Representation)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Builds a JWK envelope from a single key entry.
    private func jwk(for entry: IssuerKey) -> JWK {
        // P-256 uncompressed point: 0x04 || x (32) || y (32).
        let raw = entry.signer.publicKey.x963Representation
        let xy = raw.dropFirst()    // skip the 0x04 format byte
        let x = xy.prefix(32)
        let y = xy.suffix(32)
        return JWK(
            kty: "EC",
            crv: "P-256",
            alg: "ES256",
            use: "sig",
            kid: entry.kid,
            x: Self.base64URL(x),
            y: Self.base64URL(y)
        )
    }

    /// Canonical JSON encoding — sorted keys, no escape
    /// whitespace. We control both sides of this encoding so
    /// the "which JSON" problem doesn't bite us, but sorted
    /// keys keeps test golden output stable.
    private func stableJSON(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    /// base64url without padding, per RFC 4648 §5 / RFC 7515.
    public static func base64URL<T: Sequence>(_ bytes: T) -> String where T.Element == UInt8 {
        let data = Data(bytes)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URL(_ data: Data) -> String {
        base64URL(Array(data))
    }
}

// MARK: - Key set value types

/// One entry in the JWKS key set — a ``P256Signer`` paired with its
/// precomputed `kid` so we don't rederive the hash on every mint or
/// discovery call.
public struct IssuerKey: Sendable {
    public let signer: any P256Signer
    public let kid: String

    public init(signer: any P256Signer) {
        self.signer = signer
        self.kid = WorkloadTokenIssuer.deriveKID(from: signer.publicKey)
    }

    public init(signer: any P256Signer, kid: String) {
        self.signer = signer
        self.kid = kid
    }
}

/// A current + optional previous signing key pair, serving the JWKS
/// endpoint during a rotation overlap window.
public struct IssuerKeySet: Sendable {
    public let current: IssuerKey
    public let previous: IssuerKey?

    public init(current: IssuerKey, previous: IssuerKey? = nil) {
        self.current = current
        self.previous = previous
    }

    /// Single-key convenience — the starting state for any issuer
    /// that has never rotated.
    public static func single(_ signer: any P256Signer) -> IssuerKeySet {
        IssuerKeySet(current: IssuerKey(signer: signer), previous: nil)
    }
}

// MARK: - JWKS / Discovery document types

/// A single JSON Web Key (RFC 7517) for a P-256 EC public key.
public struct JWK: Codable, Sendable {
    public let kty: String     // "EC"
    public let crv: String     // "P-256"
    public let alg: String     // "ES256"
    public let use: String     // "sig"
    public let kid: String
    public let x: String       // base64url(32-byte x)
    public let y: String       // base64url(32-byte y)

    public init(
        kty: String, crv: String, alg: String, use: String,
        kid: String, x: String, y: String
    ) {
        self.kty = kty; self.crv = crv; self.alg = alg; self.use = use
        self.kid = kid; self.x = x; self.y = y
    }
}

/// The JWKS envelope served at `/.well-known/jwks.json`.
public struct JWKSDocument: Codable, Sendable {
    public let keys: [JWK]
    public init(keys: [JWK]) { self.keys = keys }
}

/// The minimum OIDC discovery document AWS IAM requires.
///
/// `authorization_endpoint` / `token_endpoint` are NOT included
/// — AWS's `AssumeRoleWithWebIdentity` path doesn't consult
/// them (the JWT is already issued; we're not running an
/// interactive OAuth flow). Including them with dummy URLs
/// would mislead other OIDC consumers that DO follow the flow.
public struct OIDCDiscoveryDocument: Codable, Sendable {
    public let issuer: String
    public let jwksURI: String
    public let responseTypesSupported: [String]
    public let subjectTypesSupported: [String]
    public let idTokenSigningAlgValuesSupported: [String]
    public let claimsSupported: [String]

    enum CodingKeys: String, CodingKey {
        case issuer
        case jwksURI = "jwks_uri"
        case responseTypesSupported = "response_types_supported"
        case subjectTypesSupported = "subject_types_supported"
        case idTokenSigningAlgValuesSupported = "id_token_signing_alg_values_supported"
        case claimsSupported = "claims_supported"
    }

    public init(
        issuer: String, jwksURI: String,
        responseTypesSupported: [String],
        subjectTypesSupported: [String],
        idTokenSigningAlgValuesSupported: [String],
        claimsSupported: [String]
    ) {
        self.issuer = issuer
        self.jwksURI = jwksURI
        self.responseTypesSupported = responseTypesSupported
        self.subjectTypesSupported = subjectTypesSupported
        self.idTokenSigningAlgValuesSupported = idTokenSigningAlgValuesSupported
        self.claimsSupported = claimsSupported
    }
}

// MARK: - String utilities

private extension String {
    var trimmingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
