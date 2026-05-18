import Testing
import Foundation
import CryptoKit
@testable import SpooktacularApplication
@testable import SpooktacularCore

/// Tests for ``WorkloadTokenIssuer`` — the ES256 JWT issuer
/// that makes Spooktacular a federated OIDC identity provider
/// for its managed VMs.
///
/// The contract these tests pin is what AWS STS
/// `AssumeRoleWithWebIdentity` verifies:
///
/// 1. JWT header.alg == "ES256" (AWS's accepted set:
///    RS256/384/512 + ES256/384/512).
/// 2. JWT header.kid matches a kid in the JWKS document.
/// 3. Signature is the raw 64-byte r‖s form (not DER) —
///    the most common ES256 JWT bug.
/// 4. JWK public key reconstructs to the same P-256 point
///    that signed the JWT (x, y are base64url 32-byte halves
///    of the x963 representation).
/// 5. Required OIDC claims present: iss, sub, aud, iat, exp.
/// 6. Discovery document lists the exact claims + algs AWS
///    expects (id_token_signing_alg_values_supported etc.).
@Suite("WorkloadTokenIssuer", .tags(.security, .cryptography, .identity))
struct WorkloadTokenIssuerTests {

    private static func makeIssuer(
        issuerURL: String = "https://spook.example.com"
    ) -> (WorkloadTokenIssuer, P256.Signing.PrivateKey) {
        let key = P256.Signing.PrivateKey()
        return (WorkloadTokenIssuer(issuerURL: issuerURL, signer: key), key)
    }

    // MARK: - JWT structure

    @Test("Token is a valid three-part JWT")
    func threePartShape() throws {
        let (issuer, _) = Self.makeIssuer()
        let token = try issuer.mintToken(
            subject: "vm/ci-runner-01",
            audience: "sts.amazonaws.com"
        )
        let parts = token.split(separator: ".")
        #expect(parts.count == 3)
    }

    @Test("Header declares alg=ES256 and a stable kid")
    func headerFields() throws {
        let (issuer, _) = Self.makeIssuer()
        let token = try issuer.mintToken(
            subject: "vm/runner", audience: "sts.amazonaws.com"
        )
        let parts = token.split(separator: ".")
        let headerJSON = try base64URLDecode(String(parts[0]))
        let header = try JSONSerialization.jsonObject(with: headerJSON) as! [String: Any]
        #expect(header["alg"] as? String == "ES256")
        #expect(header["typ"] as? String == "JWT")
        #expect(header["kid"] as? String == issuer.kid)
    }

    @Test("Required OIDC claims are all present")
    func requiredClaims() throws {
        let (issuer, _) = Self.makeIssuer(issuerURL: "https://spook.acme.com")
        let before = Date()
        let token = try issuer.mintToken(
            subject: "vm/ci-runner-17",
            audience: "sts.amazonaws.com",
            tenant: TenantID("acme")
        )
        let after = Date()
        let parts = token.split(separator: ".")
        let payload = try base64URLDecode(String(parts[1]))
        let claims = try JSONSerialization.jsonObject(with: payload) as! [String: Any]

        #expect(claims["iss"] as? String == "https://spook.acme.com")
        #expect(claims["sub"] as? String == "vm/ci-runner-17")
        #expect(claims["aud"] as? String == "sts.amazonaws.com")
        #expect(claims["tenant"] as? String == "acme")
        #expect(claims["jti"] is String)

        let iat = claims["iat"] as! Int
        let exp = claims["exp"] as! Int
        let nbf = claims["nbf"] as! Int
        #expect(iat >= Int(before.timeIntervalSince1970))
        #expect(iat <= Int(after.timeIntervalSince1970))
        #expect(exp == iat + Int(WorkloadTokenIssuer.defaultTokenTTL))
        #expect(nbf == iat)
    }

    @Test("Additional claims are carried through")
    func additionalClaims() throws {
        let (issuer, _) = Self.makeIssuer()
        let token = try issuer.mintToken(
            subject: "vm/runner",
            audience: "sts.amazonaws.com",
            additionalClaims: ["workload": "github-actions-runner", "pool": "large"]
        )
        let parts = token.split(separator: ".")
        let payload = try base64URLDecode(String(parts[1]))
        let claims = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        #expect(claims["workload"] as? String == "github-actions-runner")
        #expect(claims["pool"] as? String == "large")
    }

    // MARK: - Signature verification (the AWS-compat gotcha)

    @Test("Signature is raw 64-byte r‖s (not DER) — ES256 JWT-compatible")
    func rawSignatureNotDER() throws {
        let (issuer, key) = Self.makeIssuer()
        let token = try issuer.mintToken(
            subject: "vm/runner", audience: "sts.amazonaws.com"
        )
        let parts = token.split(separator: ".")
        let signingInput = "\(parts[0]).\(parts[1])"
        let signature = try base64URLDecode(String(parts[2]))

        // Must be exactly 64 bytes (32 r + 32 s) — DER would be
        // ~70-72 bytes with ASN.1 framing. This test catches the
        // single most common ES256 JWT interop bug.
        #expect(signature.count == 64,
                "ES256 JWTs require raw r‖s (64 bytes); got \(signature.count)")

        // Signature verifies with the matching public key.
        let ecdsa = try P256.Signing.ECDSASignature(rawRepresentation: signature)
        #expect(key.publicKey.isValidSignature(ecdsa, for: Data(signingInput.utf8)))
    }

    // MARK: - JWKS correctness

    @Test("JWKS x and y reconstruct the signing public key exactly")
    func jwksKeyReconstruction() throws {
        let (issuer, key) = Self.makeIssuer()
        let jwk = issuer.jwk()
        #expect(jwk.kty == "EC")
        #expect(jwk.crv == "P-256")
        #expect(jwk.alg == "ES256")
        #expect(jwk.use == "sig")
        #expect(jwk.kid == issuer.kid)

        // Reassemble x963 from the JWK: 0x04 || x (32) || y (32).
        let x = try base64URLDecode(jwk.x)
        let y = try base64URLDecode(jwk.y)
        #expect(x.count == 32, "P-256 x must be 32 bytes")
        #expect(y.count == 32, "P-256 y must be 32 bytes")
        var reconstructed = Data([0x04])
        reconstructed.append(x)
        reconstructed.append(y)

        let rebuilt = try P256.Signing.PublicKey(x963Representation: reconstructed)
        #expect(rebuilt.x963Representation == key.publicKey.x963Representation)
    }

    @Test("JWKS document contains exactly one key (single-key issuer)")
    func jwksSingleKey() {
        let (issuer, _) = Self.makeIssuer()
        #expect(issuer.jwks().keys.count == 1)
    }

    @Test("kid is stable across mints for the same key")
    func kidStable() throws {
        let (issuer, _) = Self.makeIssuer()
        let a = try issuer.mintToken(subject: "a", audience: "x")
        let b = try issuer.mintToken(subject: "b", audience: "x")
        let headerA = try JSONSerialization.jsonObject(
            with: base64URLDecode(String(a.split(separator: ".")[0]))
        ) as! [String: Any]
        let headerB = try JSONSerialization.jsonObject(
            with: base64URLDecode(String(b.split(separator: ".")[0]))
        ) as! [String: Any]
        #expect(headerA["kid"] as? String == headerB["kid"] as? String)
    }

    @Test("Different keys produce different kids")
    func kidDifferentiates() {
        let (a, _) = Self.makeIssuer()
        let (b, _) = Self.makeIssuer()
        #expect(a.kid != b.kid)
    }

    // MARK: - Discovery document (AWS IAM requirements)

    @Test("Discovery document lists ES256 in id_token_signing_alg_values_supported")
    func discoveryAlgValues() {
        let (issuer, _) = Self.makeIssuer()
        let discovery = issuer.discovery()
        #expect(discovery.idTokenSigningAlgValuesSupported.contains("ES256"))
    }

    @Test("Discovery document lists required subject + response types")
    func discoveryRequiredTypes() {
        let (issuer, _) = Self.makeIssuer()
        let discovery = issuer.discovery()
        #expect(discovery.responseTypesSupported.contains("id_token"))
        #expect(discovery.subjectTypesSupported.contains("public"))
    }

    @Test("Discovery document issuer matches configured URL exactly")
    func discoveryIssuerMatches() {
        let (issuer, _) = Self.makeIssuer(issuerURL: "https://spook.acme.com")
        let discovery = issuer.discovery()
        #expect(discovery.issuer == "https://spook.acme.com")
        #expect(discovery.jwksURI == "https://spook.acme.com/.well-known/jwks.json")
    }

    @Test("Discovery trims trailing slash from issuer URL in jwks_uri")
    func discoveryTrailingSlash() {
        let (issuer, _) = Self.makeIssuer(issuerURL: "https://spook.acme.com/")
        #expect(issuer.discovery().jwksURI == "https://spook.acme.com/.well-known/jwks.json")
    }

    @Test("Discovery claims_supported includes the OIDC minimum")
    func discoveryClaims() {
        let (issuer, _) = Self.makeIssuer()
        let discovery = issuer.discovery()
        for required in ["iss", "sub", "aud", "iat", "exp"] {
            #expect(discovery.claimsSupported.contains(required),
                    "claims_supported must include '\(required)'")
        }
    }

    // MARK: - Rotation

    @Test("rotated() promotes new key and keeps old in JWKS overlap")
    func rotationOverlap() throws {
        let (original, originalKey) = Self.makeIssuer()
        let next = P256.Signing.PrivateKey()
        let rotated = original.rotated(to: next)

        // Current kid is the new key's fingerprint.
        let expectedNewKid = WorkloadTokenIssuer.deriveKID(from: next.publicKey)
        #expect(rotated.kid == expectedNewKid)

        // JWKS serves both keys during the overlap.
        let jwks = rotated.jwks()
        #expect(jwks.keys.count == 2)
        let kids = Set(jwks.keys.map(\.kid))
        #expect(kids.contains(expectedNewKid))
        #expect(kids.contains(WorkloadTokenIssuer.deriveKID(from: originalKey.publicKey)))
    }

    @Test("tokens minted after rotation carry the new kid")
    func rotationMintsWithCurrentKid() throws {
        let (original, _) = Self.makeIssuer()
        let next = P256.Signing.PrivateKey()
        let rotated = original.rotated(to: next)
        let token = try rotated.mintToken(subject: "vm/x", audience: "sts.amazonaws.com")
        let headerJSON = try base64URLDecode(String(token.split(separator: ".")[0]))
        let header = try JSONSerialization.jsonObject(with: headerJSON) as! [String: Any]
        #expect(header["kid"] as? String == rotated.kid)
        #expect(header["kid"] as? String == WorkloadTokenIssuer.deriveKID(from: next.publicKey))
    }

    @Test("second rotation evicts the oldest key (no triple-key JWKS)")
    func rotationTwoStepDropsOldest() throws {
        let (original, _) = Self.makeIssuer()
        let k2 = P256.Signing.PrivateKey()
        let k3 = P256.Signing.PrivateKey()
        let afterFirst = original.rotated(to: k2)
        let afterSecond = afterFirst.rotated(to: k3)
        #expect(afterSecond.jwks().keys.count == 2)
        let kids = Set(afterSecond.jwks().keys.map(\.kid))
        #expect(kids.contains(WorkloadTokenIssuer.deriveKID(from: k2.publicKey)))
        #expect(kids.contains(WorkloadTokenIssuer.deriveKID(from: k3.publicKey)))
    }

    // MARK: - Helpers

    private func base64URLDecode(_ string: String) throws -> Data {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else {
            Issue.record("Malformed base64url: \(string)")
            return Data()
        }
        return data
    }
}
