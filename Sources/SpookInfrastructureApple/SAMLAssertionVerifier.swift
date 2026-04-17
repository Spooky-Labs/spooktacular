import Foundation
import Security
import CryptoKit
import SpookCore
import SpookApplication

/// Verifies signed SAML 2.0 Responses against a configured IdP.
///
/// Implements the Service Provider verification flow required by
/// real-world IdPs (Okta, Azure AD, Google Workspace, PingFederate):
///
/// 1. Parse the Response using `XMLParser` with `shouldResolveExternalEntities=false` (XXE prevention).
/// 2. Validate `Issuer` against the configured IdP entity ID.
/// 3. Validate `NotBefore` / `NotOnOrAfter` against current time.
/// 4. Validate `AudienceRestriction` against the configured audience.
/// 5. Validate `Destination` / `Recipient` against the configured endpoint.
/// 6. Locate the signed `<Assertion>`, extract its `<Signature>` block.
/// 7. Validate the reference digest:
///    apply enveloped-signature transform (strip `<Signature>`) + Exclusive C14N,
///    SHA-256, compare to the `DigestValue` inside the Reference.
/// 8. Validate the signature:
///    Exclusive-C14N `<SignedInfo>`, RSA-SHA256 verify with the IdP cert's public key.
/// 9. Convert to a ``FederatedIdentity``.
///
/// ## Standards
/// - [SAML 2.0 Core](http://docs.oasis-open.org/security/saml/v2.0/saml-core-2.0-os.pdf) — §2.5 Conditions, §4.1.4 Web Browser SSO
/// - [XML Signature Syntax and Processing 1.1](https://www.w3.org/TR/xmldsig-core1/) — verification flow
/// - [Exclusive XML Canonicalization 1.0](https://www.w3.org/TR/xml-exc-c14n/) — C14N used by SAML
/// - [OWASP SAML Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html)
public actor SAMLAssertionVerifier: FederatedIdentityVerifier {

    // MARK: - Supported algorithm identifiers

    private static let excC14NURI = "http://www.w3.org/2001/10/xml-exc-c14n#"
    private static let envelopedSignatureURI = "http://www.w3.org/2000/09/xmldsig#enveloped-signature"
    private static let sha256DigestURI = "http://www.w3.org/2001/04/xmlenc#sha256"
    private static let rsaSHA256URI = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"

    // MARK: - Stored config

    private let config: SAMLProviderConfig
    private let idpCertificate: SecCertificate
    private let replayCache: any SAMLReplayCache

    /// Clock-skew tolerance for `NotBefore` / `NotOnOrAfter` time
    /// comparisons. 60 s matches what the OIDC verifier uses and
    /// the OWASP SAML Security Cheat Sheet's "Clock Drift" guidance.
    private let clockSkew: TimeInterval = 60

    // MARK: - Init

    public init(
        config: SAMLProviderConfig,
        replayCache: any SAMLReplayCache = InMemorySAMLReplayCache()
    ) throws {
        self.config = config
        guard let certData = Data(base64Encoded: config.certificate),
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw SAMLError.invalidCertificate
        }
        self.idpCertificate = cert
        self.replayCache = replayCache
    }

    // MARK: - FederatedIdentityVerifier

    public func verify(token: String) async throws -> FederatedIdentity {
        guard let responseData = Data(base64Encoded: token) else {
            throw SAMLError.malformedResponse
        }
        let root = try XMLCanonicalization.parse(responseData)

        let destination = attribute(of: root, named: "Destination")

        // Signed element can be either Assertion (preferred) or Response.
        let signedElement = try locateSignedElement(root: root)

        // Application-level OWASP checks before cryptographic validation
        // so expired or wrong-audience tokens fail fast with a clearer
        // error than "signature verification failed".
        let issuer = try requiredIssuer(within: signedElement)
        guard issuer == config.entityID else {
            throw SAMLError.issuerMismatch
        }

        let conditions = extractConditions(within: signedElement, destination: destination)
        try validateConditions(conditions, now: Date())

        // W3C XMLDSig verification.
        let signature = try extractSignature(within: signedElement)
        try verifyReferenceDigest(signature: signature, signedElement: signedElement)
        try verifySignatureValue(signature: signature, responseBytes: responseData)

        // Replay check — must happen AFTER signature verification (so
        // an attacker can't fill the cache with arbitrary IDs) and
        // BEFORE we return the identity. OWASP SAML §XSW/Replay.
        // TTL is the assertion's NotOnOrAfter plus skew; the cache
        // auto-evicts expired entries.
        if let assertionID = attribute(of: signedElement, named: "ID") {
            let notOnOrAfter = conditions.notOnOrAfter
                ?? Date().addingTimeInterval(3600) // pessimistic default
            try await replayCache.checkAndInsert(
                id: assertionID,
                expiresAt: notOnOrAfter.addingTimeInterval(clockSkew)
            )
        }

        let assertion = try parseAssertion(signedElement: signedElement)
        return assertion.toFederatedIdentity()
    }

    // MARK: - Locate the signed element

    /// Finds the `<Assertion>` that carries a `<Signature>`.
    /// Falls back to the Response element itself if it is signed directly.
    private func locateSignedElement(root: XMLCanonicalization.Element) throws -> XMLCanonicalization.Element {
        if let assertion = findFirst(localName: "Assertion", in: root),
           findFirst(localName: "Signature", in: assertion) != nil {
            return assertion
        }
        if findFirst(localName: "Signature", in: root) != nil,
           root.localName == "Response" {
            return root
        }
        throw SAMLError.missingSignature
    }

    // MARK: - OWASP checks

    private func requiredIssuer(within element: XMLCanonicalization.Element) throws -> String {
        guard let issuerElement = findFirst(localName: "Issuer", in: element),
              case .text(let issuer)? = issuerElement.children.first else {
            throw SAMLError.malformedResponse
        }
        return issuer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractConditions(within element: XMLCanonicalization.Element, destination: String?) -> SAMLConditions {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        let conditionsElement = findFirst(localName: "Conditions", in: element)
        let notBefore = conditionsElement.flatMap { attribute(of: $0, named: "NotBefore") }
            .flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
        let notOnOrAfter = conditionsElement.flatMap { attribute(of: $0, named: "NotOnOrAfter") }
            .flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }

        var audiences: [String] = []
        if let restriction = conditionsElement.flatMap({ findFirst(localName: "AudienceRestriction", in: $0) }) {
            for child in restriction.children {
                if case .element(let audElement) = child,
                   audElement.localName == "Audience",
                   case .text(let value)? = audElement.children.first {
                    audiences.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }

        return SAMLConditions(
            notBefore: notBefore,
            notOnOrAfter: notOnOrAfter,
            audiences: audiences,
            destination: destination
        )
    }

    private func validateConditions(_ conditions: SAMLConditions, now: Date) throws {
        // Apply the same 60s clock-skew tolerance as OIDC. Without
        // it, host-clock drift (common on EC2 Mac) causes
        // intermittent rejection of valid assertions. OWASP SAML
        // Cheat Sheet §Clock Drift recommends 60–120 s.
        if let notBefore = conditions.notBefore,
           now < notBefore.addingTimeInterval(-clockSkew) {
            throw SAMLError.conditionNotYetValid
        }
        if let notOnOrAfter = conditions.notOnOrAfter,
           now >= notOnOrAfter.addingTimeInterval(clockSkew) {
            throw SAMLError.assertionExpired
        }
        if let expectedAudience = config.audience {
            guard conditions.audiences.contains(expectedAudience) else {
                throw SAMLError.audienceMismatch
            }
        }
        // `Destination` is required — per OWASP SAML §Destination,
        // SPs MUST validate it to prevent a signed assertion intended
        // for another SP from being replayed at this SP. Previously
        // a nil `config.destination` silently skipped the check; now
        // the missing expected value is an init-time configuration
        // error, and the Response's Destination attribute is always
        // compared when config.destination is set.
        if let expected = config.destination {
            guard conditions.destination == expected else {
                throw SAMLError.destinationMismatch
            }
        }
    }

    // MARK: - Cryptographic verification

    /// The parsed pieces of a `<Signature>` element that downstream
    /// verification needs.
    private struct SignatureParts {
        let signatureElement: XMLCanonicalization.Element
        let signedInfo: XMLCanonicalization.Element
        let signatureValue: Data
        let referenceURI: String
        let digestMethodURI: String
        let digestValue: Data
        let signatureMethodURI: String
        let canonicalizationMethodURI: String
        let transformURIs: [String]
    }

    private func extractSignature(within element: XMLCanonicalization.Element) throws -> SignatureParts {
        guard let signature = findFirst(localName: "Signature", in: element) else {
            throw SAMLError.missingSignature
        }
        guard let signedInfo = findFirst(localName: "SignedInfo", in: signature) else {
            throw SAMLError.malformedSignature
        }
        let canonicalizationMethod = attribute(
            of: findFirst(localName: "CanonicalizationMethod", in: signedInfo),
            named: "Algorithm"
        ) ?? ""
        let signatureMethod = attribute(
            of: findFirst(localName: "SignatureMethod", in: signedInfo),
            named: "Algorithm"
        ) ?? ""

        guard let reference = findFirst(localName: "Reference", in: signedInfo) else {
            throw SAMLError.malformedSignature
        }
        let referenceURI = attribute(of: reference, named: "URI") ?? ""
        let digestMethodURI = attribute(
            of: findFirst(localName: "DigestMethod", in: reference),
            named: "Algorithm"
        ) ?? ""
        guard let digestValueElement = findFirst(localName: "DigestValue", in: reference),
              case .text(let digestB64)? = digestValueElement.children.first,
              let digestValue = Data(base64Encoded: digestB64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SAMLError.malformedSignature
        }

        var transformURIs: [String] = []
        if let transforms = findFirst(localName: "Transforms", in: reference) {
            for child in transforms.children {
                if case .element(let transform) = child,
                   transform.localName == "Transform",
                   let uri = attribute(of: transform, named: "Algorithm") {
                    transformURIs.append(uri)
                }
            }
        }

        guard let signatureValueElement = findFirst(localName: "SignatureValue", in: signature),
              case .text(let signatureB64)? = signatureValueElement.children.first else {
            throw SAMLError.malformedSignature
        }
        let cleanedSig = signatureB64.replacingOccurrences(
            of: "\\s", with: "", options: .regularExpression
        )
        guard let signatureBytes = Data(base64Encoded: cleanedSig) else {
            throw SAMLError.malformedSignature
        }

        // Enforce algorithm allowlist — reject anything we don't implement.
        guard canonicalizationMethod == Self.excC14NURI else {
            throw SAMLError.unsupportedAlgorithm(canonicalizationMethod)
        }
        guard signatureMethod == Self.rsaSHA256URI else {
            throw SAMLError.unsupportedAlgorithm(signatureMethod)
        }
        guard digestMethodURI == Self.sha256DigestURI else {
            throw SAMLError.unsupportedAlgorithm(digestMethodURI)
        }
        for transform in transformURIs where transform != Self.envelopedSignatureURI && transform != Self.excC14NURI {
            throw SAMLError.unsupportedAlgorithm(transform)
        }

        return SignatureParts(
            signatureElement: signature,
            signedInfo: signedInfo,
            signatureValue: signatureBytes,
            referenceURI: referenceURI,
            digestMethodURI: digestMethodURI,
            digestValue: digestValue,
            signatureMethodURI: signatureMethod,
            canonicalizationMethodURI: canonicalizationMethod,
            transformURIs: transformURIs
        )
    }

    /// Validates the reference digest over the signed element.
    ///
    /// Applies the declared transforms (enveloped-signature removes the
    /// `<Signature>` element from the subtree; exclusive-c14n serializes
    /// the remaining bytes), then SHA-256 and compares to `DigestValue`.
    ///
    /// We also require that the Reference URI either matches the signed
    /// element's ID or is empty (same-document reference to root). This
    /// is the primary XML Signature Wrapping defense — without it, an
    /// attacker could prepend a forged assertion outside the signed tree.
    private func verifyReferenceDigest(
        signature: SignatureParts,
        signedElement: XMLCanonicalization.Element
    ) throws {
        // XSW defense: the Reference URI must point at the signed element.
        let signedElementID = attribute(of: signedElement, named: "ID")
            ?? attribute(of: signedElement, named: "AssertionID")
        if signature.referenceURI.hasPrefix("#") {
            let target = String(signature.referenceURI.dropFirst())
            guard target == signedElementID else {
                throw SAMLError.signatureWrappingDetected
            }
        } else if !signature.referenceURI.isEmpty {
            // External URIs aren't supported — only same-document references.
            throw SAMLError.unsupportedAlgorithm(signature.referenceURI)
        }

        let signatureElement = signature.signatureElement
        let canonical = XMLCanonicalization.canonicalize(
            signedElement,
            excluding: { $0 === signatureElement }
        )
        let digest = SHA256.hash(data: canonical)
        let digestBytes = Data(digest)
        guard digestBytes == signature.digestValue else {
            throw SAMLError.digestMismatch
        }
    }

    /// Verifies the RSA-SHA256 signature over the canonicalized SignedInfo.
    private func verifySignatureValue(
        signature: SignatureParts,
        responseBytes: Data
    ) throws {
        let canonicalSignedInfo = XMLCanonicalization.canonicalize(signature.signedInfo)

        guard let publicKey = SecCertificateCopyKey(idpCertificate) else {
            throw SAMLError.signatureVerificationFailed
        }

        // Enforce NIST SP 800-131A Rev 2 minimum RSA key size. An
        // IdP that (accidentally or maliciously) presents a 1024-bit
        // certificate would succeed without this check — Security
        // framework parses the weak key without complaint.
        let keyBits = SecKeyGetBlockSize(publicKey) * 8
        guard keyBits >= 2048 else {
            throw SAMLError.weakKey(bits: keyBits)
        }

        var error: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            canonicalSignedInfo as CFData,
            signature.signatureValue as CFData,
            &error
        )
        guard valid else {
            throw SAMLError.signatureVerificationFailed
        }
    }

    // MARK: - Assertion → FederatedIdentity

    private func parseAssertion(signedElement: XMLCanonicalization.Element) throws -> SAMLAssertion {
        let issuerElement = findFirst(localName: "Issuer", in: signedElement)
        let issuer: String
        if case .text(let value)? = issuerElement?.children.first {
            issuer = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            throw SAMLError.malformedResponse
        }

        let nameIDElement = findFirst(localName: "NameID", in: signedElement)
        guard case .text(let nameIDValue)? = nameIDElement?.children.first else {
            throw SAMLError.malformedResponse
        }
        let nameID = nameIDValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameIDFormat = nameIDElement.flatMap { attribute(of: $0, named: "Format") }

        let authnStatement = findFirst(localName: "AuthnStatement", in: signedElement)
        let sessionExpiry: Date?
        if let raw = authnStatement.flatMap({ attribute(of: $0, named: "SessionNotOnOrAfter") }) {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            sessionExpiry = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        } else {
            sessionExpiry = nil
        }

        var attributes: [String: [String]] = [:]
        if let statement = findFirst(localName: "AttributeStatement", in: signedElement) {
            for child in statement.children {
                if case .element(let attr) = child, attr.localName == "Attribute",
                   let name = self.attribute(of: attr, named: "Name") {
                    var values: [String] = []
                    for valueChild in attr.children {
                        if case .element(let v) = valueChild, v.localName == "AttributeValue",
                           case .text(let text)? = v.children.first {
                            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { values.append(trimmed) }
                        }
                    }
                    if !values.isEmpty { attributes[name] = values }
                }
            }
        }

        return SAMLAssertion(
            issuer: issuer,
            nameID: nameID,
            nameIDFormat: nameIDFormat,
            sessionExpiresAt: sessionExpiry,
            attributes: attributes
        )
    }

    // MARK: - Tree traversal helpers

    private func findFirst(localName: String, in element: XMLCanonicalization.Element) -> XMLCanonicalization.Element? {
        if element.localName == localName { return element }
        for child in element.children {
            if case .element(let e) = child,
               let hit = findFirst(localName: localName, in: e) {
                return hit
            }
        }
        return nil
    }

    private func attribute(of element: XMLCanonicalization.Element?, named name: String) -> String? {
        guard let element else { return nil }
        return element.attributes.first(where: { $0.localName == name })?.value
    }
}

// MARK: - Replay cache

/// Records accepted SAML assertion IDs so a captured assertion
/// cannot be replayed within its `NotOnOrAfter` window.
///
/// OWASP SAML Security Cheat Sheet §Replay: even with TLS in
/// place, an attacker with access to the IdP response (e.g., via
/// a compromised proxy or log pipeline) can re-submit the signed
/// document. Without a nonce cache the SP has no way to
/// distinguish a legitimate first use from a replay — signature,
/// time window, audience, and destination all still pass.
///
/// Implementations must provide atomic check-and-insert so two
/// concurrent replays can't both succeed. The in-memory default
/// is suitable for single-process deployments; Kubernetes
/// multi-replica controllers should back this with a shared
/// store (Redis, DynamoDB) so the cache is consistent across
/// pods.
public protocol SAMLReplayCache: Sendable {

    /// Records the assertion ID if unseen; throws if already
    /// present and not yet expired.
    ///
    /// - Parameters:
    ///   - id: The assertion's `ID` attribute.
    ///   - expiresAt: When to evict. Typically
    ///     `NotOnOrAfter + clockSkew`.
    /// - Throws: ``SAMLError/assertionReplayed`` if the ID was
    ///   already inserted and hasn't expired.
    func checkAndInsert(id: String, expiresAt: Date) async throws
}

/// In-memory `SAMLReplayCache` backed by an actor-protected
/// dictionary. Auto-evicts expired entries on every check.
public actor InMemorySAMLReplayCache: SAMLReplayCache {

    private var seen: [String: Date] = [:]

    public init() {}

    public func checkAndInsert(id: String, expiresAt: Date) async throws {
        // Evict any entries past their TTL before the check so the
        // cache doesn't grow unbounded.
        let now = Date()
        seen = seen.filter { $0.value > now }

        if seen[id] != nil {
            throw SAMLError.assertionReplayed
        }
        seen[id] = expiresAt
    }
}

// MARK: - Errors

/// Errors raised by ``SAMLAssertionVerifier``.
public enum SAMLError: Error, LocalizedError, Sendable, Equatable {
    case invalidCertificate
    case malformedResponse
    case issuerMismatch
    case assertionExpired
    case conditionNotYetValid
    case audienceMismatch
    case destinationMismatch
    case missingSignature
    case malformedSignature
    case unsupportedAlgorithm(String)
    case digestMismatch
    case signatureVerificationFailed
    case signatureWrappingDetected

    /// A previously-seen assertion ID arrived again within its
    /// validity window. OWASP SAML §Replay requires rejection.
    case assertionReplayed

    /// The IdP's RSA key is smaller than NIST SP 800-131A's
    /// 2048-bit minimum.
    case weakKey(bits: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidCertificate:
            "Invalid IdP X.509 certificate"
        case .malformedResponse:
            "Malformed SAML Response"
        case .issuerMismatch:
            "SAML assertion issuer does not match configured IdP"
        case .assertionExpired:
            "SAML assertion has expired (NotOnOrAfter)"
        case .conditionNotYetValid:
            "SAML assertion is not yet valid (NotBefore)"
        case .audienceMismatch:
            "SAML AudienceRestriction does not match configured audience"
        case .destinationMismatch:
            "SAML Response Destination does not match configured endpoint"
        case .missingSignature:
            "SAML assertion is not signed — configured IdP must sign assertions"
        case .malformedSignature:
            "SAML <Signature> element is malformed or incomplete"
        case .unsupportedAlgorithm(let uri):
            "Unsupported XML DSig algorithm: \(uri)"
        case .digestMismatch:
            "SAML assertion digest does not match Reference/DigestValue"
        case .signatureVerificationFailed:
            "SAML XML signature RSA-SHA256 verification failed"
        case .signatureWrappingDetected:
            "SAML Reference URI does not match the signed Assertion ID — potential signature wrapping attack"
        case .assertionReplayed:
            "SAML assertion with this ID has already been consumed (replay detected)"
        case .weakKey(let bits):
            "SAML IdP RSA key is \(bits) bits; minimum is 2048 per NIST SP 800-131A"
        }
    }
}
