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

    // MARK: - Init

    public init(config: SAMLProviderConfig) throws {
        self.config = config
        guard let certData = Data(base64Encoded: config.certificate),
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw SAMLError.invalidCertificate
        }
        self.idpCertificate = cert
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
        if let notBefore = conditions.notBefore, now < notBefore {
            throw SAMLError.conditionNotYetValid
        }
        if let notOnOrAfter = conditions.notOnOrAfter, now >= notOnOrAfter {
            throw SAMLError.assertionExpired
        }
        if let expectedAudience = config.audience {
            guard conditions.audiences.contains(expectedAudience) else {
                throw SAMLError.audienceMismatch
            }
        }
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
        }
    }
}
