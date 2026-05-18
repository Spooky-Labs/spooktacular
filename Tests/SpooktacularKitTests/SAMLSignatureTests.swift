import Testing
import Foundation
import Security
import CryptoKit
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

/// End-to-end SAML signature verification.
///
/// These tests synthesize a signed SAML Response with the SAML profile
/// used by real IdPs (enveloped-signature + Exclusive C14N + RSA-SHA256)
/// and feed it through ``SAMLAssertionVerifier`` to prove that the full
/// W3C XMLDSig pipeline actually verifies — digest check, signature
/// check, algorithm allowlist, OWASP conditions.
///
/// The RSA-2048 test fixture below was generated **once** with:
/// ```
/// openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 36500 \
///   -subj "/CN=Spooktacular SAML Test IdP/O=Test/C=US"
/// ```
/// It is used **only for these tests** and carries no security value.
@Suite("SAML Signature Verification", .tags(.security, .cryptography, .identity))
struct SAMLSignatureTests {

    // MARK: - Test fixtures

    /// Base64-encoded X.509 DER, issued above. DER bytes only — no PEM armor.
    private static let testCertBase64 = """
    MIIDZTCCAk2gAwIBAgIUFlJZuWNTDcx+WFsRnKciRwCnJVEwDQYJKoZIhvcNAQELBQAwQTEjMCEGA1UE\
    AwwaU3Bvb2t0YWN1bGFyIFNBTUwgVGVzdCBJZFAxDTALBgNVBAoMBFRlc3QxCzAJBgNVBAYTAlVTMCAX\
    DTI2MDQxNjE4MTYxMloYDzIxMjYwMzIzMTgxNjEyWjBBMSMwIQYDVQQDDBpTcG9va3RhY3VsYXIgU0FN\
    TCBUZXN0IElkUDENMAsGA1UECgwEVGVzdDELMAkGA1UEBhMCVVMwggEiMA0GCSqGSIb3DQEBAQUAA4IB\
    DwAwggEKAoIBAQCVsiEm82LOMR2zaq67zQVjjpxP4IOB2zVmEZoVjS5+WF98kGg1sxtSSW+cF6vvjW2z\
    UlcISwYAYGn4D0nZ2S3e20iK1nvJtD0r63smMgS/va0x/KWsJh65iQo5r/zSTX3qLm9RAb87uhatqMoH\
    cf1iIcDJE+BwnHNlqVSmR4N/oDy+MA6A2FSCjjh+ev4UKAbn/aiusyH+KwYDJBi+Vb7DVN4hcpqdv+Ti\
    FWm6MVWIV2UhsNG0lI+z8J7upcTVWi+Hxf486f0a+P//ZwdZXmmaispIHbUOmtrBVQ4AmUlY5kZILzE7\
    Qcp6aZ8aa6K55D8LUhFIL7oz5/Jf6mHX1obBAgMBAAGjUzBRMB0GA1UdDgQWBBTZdwmJTLEdyd5CUFDT\
    ZOlaFzxk/zAfBgNVHSMEGDAWgBTZdwmJTLEdyd5CUFDTZOlaFzxk/zAPBgNVHRMBAf8EBTADAQH/MA0G\
    CSqGSIb3DQEBCwUAA4IBAQA6pAjzn3w9g5TeIWCHLXMJc7Keo3A1ew3+qW6g0OPHupbu8fEoqGzGtNTS\
    iyNdPvUpxLt08dRS3A9hwUh/8clYAjv48JjLudUTeNeuDxRvNnBg4e0YDSzm68kR5LrRsXbsZ40lsyru\
    mh917OLfcnJppjpxDx3di9aEwFgf1V6fsgR7BNJCn0+92EhxiTWv1mTXCeDAA7VpwEnoqilIr6kcaf4V\
    xQQz7Vrc2PRKj4t9dhLuoVC8CGwHN+qy7g5Fs9fJV4pWZO2db/00wlOPJ4zRjIXkpPztuTN1gxSfwXHr\
    Qktj23HpGCC7zI6g6HhIp5tl2fpauw/VGd0kB1TtHpVQ
    """

    /// PKCS#8 private-key DER for the matching RSA-2048 keypair, base64.
    private static let testPrivateKeyBase64 = """
    MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCVsiEm82LOMR2zaq67zQVjjpxP4IOB\
    2zVmEZoVjS5+WF98kGg1sxtSSW+cF6vvjW2zUlcISwYAYGn4D0nZ2S3e20iK1nvJtD0r63smMgS/va0x\
    /KWsJh65iQo5r/zSTX3qLm9RAb87uhatqMoHcf1iIcDJE+BwnHNlqVSmR4N/oDy+MA6A2FSCjjh+ev4U\
    KAbn/aiusyH+KwYDJBi+Vb7DVN4hcpqdv+TiFWm6MVWIV2UhsNG0lI+z8J7upcTVWi+Hxf486f0a+P//\
    ZwdZXmmaispIHbUOmtrBVQ4AmUlY5kZILzE7Qcp6aZ8aa6K55D8LUhFIL7oz5/Jf6mHX1obBAgMBAAEC\
    ggEAF6RB+h3W4qD9Li3QxNY0s1bS4bFKnlfuz1zuTIMMmbr+nEn45f+QdrwkWq7zt5SgLlb4adXiGm3K\
    WU6eJ5VWL5Z1ltUYSHB6d2pBpnRLLbZuGQaWv7Zm2dSGfzqHykr0x5G9K4+uvRG/An7gJrGJBquKqqHE\
    q4755qS0kBeb8VbbmWQOy/G7efv0aEzUy+/2gi36Ecby/NnIJroHbOPY9Lm8411tWWiMa7hE+2jRtuB3\
    0LPpTLVOcJzWGgJax5WfYWBPc2vvnzeFubfI9GtHHt3d3nrZztIlcPbPbtNqtocLOcw2uhlIwL8SU08Y\
    81M+5w/i+1SQO2sYKvNsfxQ5NQKBgQDP6wAmWrdB8XjoRaDbT2/btpaJ/wlMCjK2i2pKr4iXsE3XZt9s\
    tEGoi6AlZCnfFUZLtoW70N06zE50qgCDAfg3F+OpNBZ3y24DVI/Q4EBtXkPJgDIcosWd5xotPK6qMg9o\
    9Ol492wNS6D4M4oKMSmV2oY8D+8ZGmUUCWlBr+geMwKBgQC4UE5Q775eAK/H6NEbDquX08ZFkKnkGwNs\
    iJCadzpMEdkKLkMfwqXFtY7MngqiPljRTLyCnGT7Xx06xwd+3pfwmLfxdspC1vrh/Y2p13QFEercXVm+\
    ON3YwvD5A1yUkTDu/0ZVWRSqKXQ1wuy8aXYNgqUERiOizoT28DmX76crOwKBgHL0EM8j1LJG2XxCEt9u\
    GgA2ASEmunMqKEO47PmB91k2hrMTE3A8cRjIqbBCosvOLWFq9qGSpt39W1sxKrtD+YIsWRiRzeJJvPdm\
    Z2UqtzRAq+XaVNp0PCJDRbvBEyjSKKb00aip0zm+mK7hf+6Go+FQQmsuvBj6+OuNEH7azND1AoGAVwL6\
    ZfU4XrJeSbbceLSNR2jfslmgCqLCFAvIkFN2/xBx8P90CtteXR7gIjL9/CgI0A409EgW2CDH8MajAD7f\
    ZeMC+4hD5hgNaoDDzwl6qSYTRSMAye+Ys8sb7cKrgyuj+UAkGQir28UkKnkyP6Rd6fTiKElga2ypktZH\
    qjWmKp8CgYA+2JkguQxk08nBhy5NSS/szc3j7CdjnsURfSDkBo3eblfTGDatZGT+ntX5sUzhR528bMj4\
    T+JR/vGZSYpVodmF8nnVGT67FQ8Dpfgtw/9t3DSTWIyNRVy97002upZIignM0q9KwP94E2+owg0KWgaY\
    wwUPoJ7+oviui1D90riLkw==
    """

    /// The test issuer used throughout these tests.
    private static let issuer = "https://test-idp.spooky-labs.internal/saml"

    // MARK: - Helpers

    /// Extracts the bare RSA `SEQUENCE ( modulus, publicExponent )` from
    /// a PKCS#8 private key by loading the cert, copying the public key,
    /// and converting — Security.framework handles the ASN.1 stripping.
    private static func testCertificate() throws -> SecCertificate {
        let cleaned = testCertBase64.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            Issue.record("Failed to base64-decode test certificate")
            throw SAMLError.invalidCertificate
        }
        guard let cert = SecCertificateCreateWithData(nil, data as CFData) else {
            Issue.record("Failed to parse test certificate DER")
            throw SAMLError.invalidCertificate
        }
        return cert
    }

    /// Loads the test RSA-2048 private key via Security.framework.
    ///
    /// The PEM key is PKCS#8 — Security.framework can import it directly
    /// if we strip the PKCS#8 wrapper down to the raw RSA key. We do that
    /// here by having SecKey import the PKCS#8 and re-emit in its native
    /// PKCS#1 form.
    private static func testPrivateKey() throws -> SecKey {
        let cleaned = testPrivateKeyBase64.replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "")
        guard let pkcs8 = Data(base64Encoded: cleaned) else {
            throw SAMLError.invalidCertificate
        }

        // PKCS#8 → extract inner PKCS#1 RSAPrivateKey by skipping the
        // PrivateKeyInfo wrapper. The inner octet string at offset 26
        // (fixed for RSA-2048 PKCS#8) begins the RSAPrivateKey.
        let pkcs1 = try extractPKCS1FromPKCS8(pkcs8)

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, attrs as CFDictionary, &error) else {
            Issue.record("SecKeyCreateWithData failed: \(error?.takeRetainedValue() as Error?)")
            throw SAMLError.invalidCertificate
        }
        return key
    }

    /// Unwraps the `RSAPrivateKey` out of a `PrivateKeyInfo` (PKCS#8).
    ///
    /// PKCS#8 DER layout for an RSA-2048 private key:
    /// ```
    /// SEQUENCE {
    ///   INTEGER 0             -- version
    ///   SEQUENCE { OID rsaEncryption, NULL }   -- algorithm
    ///   OCTET STRING { <PKCS#1 RSAPrivateKey bytes> }
    /// }
    /// ```
    /// We locate the OCTET STRING and return its contents. Hand-rolled
    /// because Security.framework on some macOS versions rejects PKCS#8
    /// keys directly.
    private static func extractPKCS1FromPKCS8(_ pkcs8: Data) throws -> Data {
        var bytes = Array(pkcs8)
        var i = 0
        // Outer SEQUENCE
        try expectTag(0x30, bytes: bytes, at: &i)
        _ = try readLength(bytes: bytes, at: &i)
        // version INTEGER 0
        try expectTag(0x02, bytes: bytes, at: &i)
        let versionLen = try readLength(bytes: bytes, at: &i)
        i += versionLen
        // algorithm SEQUENCE
        try expectTag(0x30, bytes: bytes, at: &i)
        let algLen = try readLength(bytes: bytes, at: &i)
        i += algLen
        // privateKey OCTET STRING
        try expectTag(0x04, bytes: bytes, at: &i)
        let keyLen = try readLength(bytes: bytes, at: &i)
        return Data(bytes[i..<(i + keyLen)])
    }

    private static func expectTag(_ tag: UInt8, bytes: [UInt8], at i: inout Int) throws {
        guard i < bytes.count, bytes[i] == tag else {
            throw SAMLError.invalidCertificate
        }
        i += 1
    }

    private static func readLength(bytes: [UInt8], at i: inout Int) throws -> Int {
        guard i < bytes.count else { throw SAMLError.invalidCertificate }
        let first = bytes[i]
        i += 1
        if first < 0x80 { return Int(first) }
        let octets = Int(first & 0x7f)
        guard i + octets <= bytes.count else { throw SAMLError.invalidCertificate }
        var len = 0
        for _ in 0..<octets {
            len = (len << 8) | Int(bytes[i])
            i += 1
        }
        return len
    }

    /// Signs the given bytes with the test private key using RSA-SHA256.
    private static func rsaSHA256Sign(_ data: Data, privateKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            data as CFData,
            &error
        ) as Data? else {
            Issue.record("SecKeyCreateSignature failed: \(error?.takeRetainedValue() as Error?)")
            throw SAMLError.signatureVerificationFailed
        }
        return signature
    }

    /// Builds a signed SAML Response for the given assertion body.
    ///
    /// - Parameters:
    ///   - assertionInnerXML: The `<Assertion>…</Assertion>` payload with
    ///     a stable `ID="..."` attribute and all required SAML elements.
    ///   - assertionID: The `ID` attribute value — the Reference URI will
    ///     be `#<assertionID>`.
    /// - Returns: A base64-encoded SAML Response ready to pass to
    ///   ``SAMLAssertionVerifier``.
    private static func buildSignedResponse(
        assertionXML: String,
        assertionID: String,
        destination: String
    ) throws -> String {
        let privateKey = try testPrivateKey()

        // 1. Canonicalize the Assertion — no Signature is present yet,
        //    so nothing is excluded. This is the reference input that
        //    will be digested.
        let unsignedTree = try XMLCanonicalization.parse(Data(assertionXML.utf8))
        let canonicalAssertion = XMLCanonicalization.canonicalize(unsignedTree)
        let digest = Data(SHA256.hash(data: canonicalAssertion))
        let digestB64 = digest.base64EncodedString()

        // 2. Build a SignedInfo referencing the assertion ID.
        let signedInfoXML = """
        <ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">\
        <ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"></ds:CanonicalizationMethod>\
        <ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"></ds:SignatureMethod>\
        <ds:Reference URI="#\(assertionID)">\
        <ds:Transforms>\
        <ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"></ds:Transform>\
        <ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"></ds:Transform>\
        </ds:Transforms>\
        <ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"></ds:DigestMethod>\
        <ds:DigestValue>\(digestB64)</ds:DigestValue>\
        </ds:Reference>\
        </ds:SignedInfo>
        """

        // 3. Canonicalize SignedInfo and sign.
        let signedInfoTree = try XMLCanonicalization.parse(Data(signedInfoXML.utf8))
        let canonicalSignedInfo = XMLCanonicalization.canonicalize(signedInfoTree)
        let signature = try rsaSHA256Sign(canonicalSignedInfo, privateKey: privateKey)
        let signatureB64 = signature.base64EncodedString()

        // 4. Inject the full Signature element into the Assertion, and
        //    wrap the Assertion in a SAML Response envelope.
        let signedAssertion = assertionXML.replacingOccurrences(
            of: "</Assertion>",
            with: """
            <ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#">\
            \(signedInfoXML.replacingOccurrences(of: #"<ds:SignedInfo xmlns:ds="http://www.w3.org/2000/09/xmldsig#">"#, with: "<ds:SignedInfo>"))\
            <ds:SignatureValue>\(signatureB64)</ds:SignatureValue>\
            </ds:Signature></Assertion>
            """
        )

        let responseXML = """
        <samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" \
        xmlns="urn:oasis:names:tc:SAML:2.0:assertion" \
        ID="response-1" Version="2.0" IssueInstant="2026-01-01T00:00:00Z" \
        Destination="\(destination)">\
        <Issuer>\(issuer)</Issuer>\
        \(signedAssertion)\
        </samlp:Response>
        """

        return Data(responseXML.utf8).base64EncodedString()
    }

    private static func sampleAssertion(
        id: String = "assertion-1",
        nameID: String = "alice@example.com",
        notBefore: String = "2020-01-01T00:00:00Z",
        notOnOrAfter: String = "2100-01-01T00:00:00Z",
        audience: String = "https://spooktacular.example/api"
    ) -> String {
        """
        <Assertion xmlns="urn:oasis:names:tc:SAML:2.0:assertion" \
        ID="\(id)" Version="2.0" IssueInstant="2026-01-01T00:00:00Z">\
        <Issuer>\(issuer)</Issuer>\
        <Subject>\
        <NameID Format="urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress">\(nameID)</NameID>\
        </Subject>\
        <Conditions NotBefore="\(notBefore)" NotOnOrAfter="\(notOnOrAfter)">\
        <AudienceRestriction><Audience>\(audience)</Audience></AudienceRestriction>\
        </Conditions>\
        </Assertion>
        """
    }

    // MARK: - Tests

    @Test("Round-trip: synthesized signature verifies against the IdP cert")
    func roundTripVerify() async throws {
        let config = SAMLProviderConfig(
            entityID: Self.issuer,
            ssoURL: "https://test/sso",
            certificate: Self.testCertBase64.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: ""),
            audience: "https://spooktacular.example/api",
            destination: "https://spooktacular.example/acs"
        )
        let verifier = try SAMLAssertionVerifier(config: config)
        let token = try Self.buildSignedResponse(
            assertionXML: Self.sampleAssertion(),
            assertionID: "assertion-1",
            destination: "https://spooktacular.example/acs"
        )
        let identity = try await verifier.verify(token: token)
        #expect(identity.issuer == Self.issuer)
        #expect(identity.subject == "alice@example.com")
        #expect(identity.email == "alice@example.com")
    }

    @Test("Tampered assertion text fails digest check")
    func tamperingInvalidatesDigest() async throws {
        let config = SAMLProviderConfig(
            entityID: Self.issuer,
            ssoURL: "https://test/sso",
            certificate: Self.testCertBase64.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: ""),
            audience: "https://spooktacular.example/api",
            destination: "https://spooktacular.example/acs"
        )
        let verifier = try SAMLAssertionVerifier(config: config)
        var token = try Self.buildSignedResponse(
            assertionXML: Self.sampleAssertion(),
            assertionID: "assertion-1",
            destination: "https://spooktacular.example/acs"
        )
        // Tamper: decode, swap NameID, re-encode.
        var bytes = Data(base64Encoded: token) ?? Data()
        var xml = String(data: bytes, encoding: .utf8) ?? ""
        xml = xml.replacingOccurrences(of: "alice@example.com", with: "mallory@evil.com")
        bytes = Data(xml.utf8)
        token = bytes.base64EncodedString()

        await #expect(throws: SAMLError.self) {
            _ = try await verifier.verify(token: token)
        }
    }

    @Test("Wrong audience is rejected (OWASP)")
    func wrongAudienceRejected() async throws {
        let config = SAMLProviderConfig(
            entityID: Self.issuer,
            ssoURL: "https://test/sso",
            certificate: Self.testCertBase64.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: ""),
            audience: "https://expected.example/api",
            destination: nil
        )
        let verifier = try SAMLAssertionVerifier(config: config)
        let token = try Self.buildSignedResponse(
            assertionXML: Self.sampleAssertion(
                audience: "https://wrong.example/api"
            ),
            assertionID: "assertion-1",
            destination: "https://spooktacular.example/acs"
        )
        await #expect(throws: SAMLError.audienceMismatch) {
            _ = try await verifier.verify(token: token)
        }
    }

    @Test("Expired assertion (NotOnOrAfter in the past) is rejected")
    func expiredAssertionRejected() async throws {
        let config = SAMLProviderConfig(
            entityID: Self.issuer,
            ssoURL: "https://test/sso",
            certificate: Self.testCertBase64.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: "")
        )
        let verifier = try SAMLAssertionVerifier(config: config)
        let token = try Self.buildSignedResponse(
            assertionXML: Self.sampleAssertion(
                notOnOrAfter: "2000-01-01T00:00:00Z"
            ),
            assertionID: "assertion-1",
            destination: "https://spooktacular.example/acs"
        )
        await #expect(throws: SAMLError.assertionExpired) {
            _ = try await verifier.verify(token: token)
        }
    }

    @Test("Issuer mismatch is rejected (OWASP)")
    func issuerMismatchRejected() async throws {
        let config = SAMLProviderConfig(
            entityID: "https://different-idp.example/",
            ssoURL: "https://test/sso",
            certificate: Self.testCertBase64.replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\\", with: "")
        )
        let verifier = try SAMLAssertionVerifier(config: config)
        let token = try Self.buildSignedResponse(
            assertionXML: Self.sampleAssertion(),
            assertionID: "assertion-1",
            destination: "https://spooktacular.example/acs"
        )
        await #expect(throws: SAMLError.issuerMismatch) {
            _ = try await verifier.verify(token: token)
        }
    }
}
