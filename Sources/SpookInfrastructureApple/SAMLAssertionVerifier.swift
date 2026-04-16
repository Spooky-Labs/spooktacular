import Foundation
import Security
import SpookCore
import SpookApplication

/// Verifies SAML Response XML and extracts assertions.
///
/// Uses Apple's `XMLParser` (Foundation) for standards-compliant XML
/// parsing and `Security.framework` for X.509 signature verification.
///
/// ## Standards
/// - [SAML 2.0 Core (OASIS)](http://docs.oasis-open.org/security/saml/v2.0/saml-core-2.0-os.pdf)
/// - [XML Signature (W3C)](https://www.w3.org/TR/xmldsig-core1/)
/// - [OWASP SAML Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html)
public actor SAMLAssertionVerifier: FederatedIdentityVerifier {
    private let config: SAMLProviderConfig
    private let idpCertificate: SecCertificate

    public init(config: SAMLProviderConfig) throws {
        self.config = config
        guard let certData = Data(base64Encoded: config.certificate),
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw SAMLError.invalidCertificate
        }
        self.idpCertificate = cert
    }

    /// Verifies a SAML Response following OWASP SAML Security Cheat Sheet:
    /// 1. Decode and parse XML (XMLParser, not regex)
    /// 2. Validate issuer matches configured IdP
    /// 3. Validate NotBefore / NotOnOrAfter conditions
    /// 4. Validate Audience restriction (if configured)
    /// 5. Validate Destination / Recipient (if configured)
    /// 6. Verify XML signature (RSA-SHA256)
    /// 7. Extract identity claims
    ///
    /// References:
    /// - [OWASP SAML Security Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/SAML_Security_Cheat_Sheet.html)
    /// - [SAML 2.0 Core §2.5](http://docs.oasis-open.org/security/saml/v2.0/saml-core-2.0-os.pdf)
    public func verify(token: String) async throws -> FederatedIdentity {
        guard let responseData = Data(base64Encoded: token),
              let responseXML = String(data: responseData, encoding: .utf8) else {
            throw SAMLError.malformedResponse
        }

        let (assertion, conditions) = try parseAssertionWithConditions(from: responseXML)

        // 1. Issuer validation (OWASP: validate issuer)
        guard assertion.issuer == config.entityID else {
            throw SAMLError.issuerMismatch
        }

        // 2. NotBefore / NotOnOrAfter (OWASP: "Validate NotBefore and NotOnOrAfter")
        let now = Date()
        if let notBefore = conditions.notBefore, now < notBefore {
            throw SAMLError.conditionNotYetValid
        }
        if let notOnOrAfter = conditions.notOnOrAfter, now >= notOnOrAfter {
            throw SAMLError.assertionExpired
        }
        if assertion.isExpired {
            throw SAMLError.assertionExpired
        }

        // 3. Audience restriction (OWASP: validate AudienceRestriction)
        if let expectedAudience = config.audience {
            guard conditions.audiences.contains(expectedAudience) else {
                throw SAMLError.audienceMismatch
            }
        }

        // 4. Destination validation (OWASP: "Validate Recipient attribute")
        if let expectedDestination = config.destination {
            guard conditions.destination == expectedDestination else {
                throw SAMLError.destinationMismatch
            }
        }

        // 5. Verify XML signature
        try verifySignature(xml: responseXML)

        // 6. Convert to FederatedIdentity
        return assertion.toFederatedIdentity()
    }

    // MARK: - XMLParser-Based Parsing

    /// Parses a SAML assertion and conditions using Apple's XMLParser.
    /// Returns both the assertion and OWASP-required conditions.
    private func parseAssertionWithConditions(from xml: String) throws -> (SAMLAssertion, SAMLConditions) {
        let (assertion, conditions) = try parseAssertionInternal(from: xml)
        return (assertion, conditions)
    }

    private func parseAssertionInternal(from xml: String) throws -> (SAMLAssertion, SAMLConditions) {
        let assertion = try parseAssertion(from: xml)
        // Re-parse to get conditions (delegate already captured them)
        guard let data = xml.data(using: .utf8) else { throw SAMLError.malformedResponse }
        let delegate = SAMLXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        let fmt = ISO8601DateFormatter()
        let conditions = SAMLConditions(
            notBefore: delegate.notBefore.flatMap { fmt.date(from: $0) },
            notOnOrAfter: delegate.notOnOrAfter.flatMap { fmt.date(from: $0) },
            audiences: delegate.audiences,
            destination: delegate.destination
        )
        return (assertion, conditions)
    }

    /// Parses a SAML assertion using Apple's XMLParser (not regex).
    private func parseAssertion(from xml: String) throws -> SAMLAssertion {
        guard let data = xml.data(using: .utf8) else {
            throw SAMLError.malformedResponse
        }

        let delegate = SAMLXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false // Prevent XXE attacks
        guard parser.parse() else {
            throw SAMLError.malformedResponse
        }

        guard let issuer = delegate.issuer else {
            throw SAMLError.malformedResponse
        }
        guard let nameID = delegate.nameID else {
            throw SAMLError.malformedResponse
        }

        let sessionExpiry: Date?
        if let expiryStr = delegate.sessionNotOnOrAfter {
            sessionExpiry = ISO8601DateFormatter().date(from: expiryStr)
        } else {
            sessionExpiry = nil
        }

        return SAMLAssertion(
            issuer: issuer,
            nameID: nameID,
            nameIDFormat: delegate.nameIDFormat,
            sessionExpiresAt: sessionExpiry,
            attributes: delegate.attributes
        )
    }

    // MARK: - XML Signature Verification

    private func verifySignature(xml: String) throws {
        guard let data = xml.data(using: .utf8) else {
            throw SAMLError.signatureVerificationFailed
        }

        let sigDelegate = SignatureXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = sigDelegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let signatureB64 = sigDelegate.signatureValue else {
            throw SAMLError.signatureVerificationFailed
        }

        let cleanedSig = signatureB64.replacingOccurrences(
            of: "\\s", with: "", options: .regularExpression
        )
        guard let signatureData = Data(base64Encoded: cleanedSig) else {
            throw SAMLError.signatureVerificationFailed
        }

        guard let publicKey = SecCertificateCopyKey(idpCertificate) else {
            throw SAMLError.signatureVerificationFailed
        }

        // Extract SignedInfo for verification
        guard let signedInfoStart = xml.range(of: "<SignedInfo"),
              let signedInfoEnd = xml.range(of: "</SignedInfo>") else {
            throw SAMLError.signatureVerificationFailed
        }
        let signedInfo = String(xml[signedInfoStart.lowerBound...signedInfoEnd.upperBound])
        let signedInfoData = Data(signedInfo.utf8)

        var error: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            publicKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            signedInfoData as CFData,
            signatureData as CFData,
            &error
        )
        guard valid else {
            throw SAMLError.signatureVerificationFailed
        }
    }
}

// MARK: - SAML XML Parser Delegate

/// Parses SAML assertion elements using Apple's XMLParser.
///
/// Handles namespace prefixes (saml:, saml2:, unprefixed) and
/// extracts Issuer, NameID, Attributes, and SessionNotOnOrAfter.
/// `shouldResolveExternalEntities = false` prevents XXE attacks.
private final class SAMLXMLParserDelegate: NSObject, XMLParserDelegate {
    var issuer: String?
    var nameID: String?
    var nameIDFormat: String?
    var sessionNotOnOrAfter: String?
    var attributes: [String: [String]] = [:]
    // OWASP conditions
    var notBefore: String?
    var notOnOrAfter: String?
    var audiences: [String] = []
    var destination: String?

    private var currentElement: String?
    private var currentText = ""
    private var currentAttributeName: String?
    private var currentAttributeValues: [String] = []
    private var inAttributeValue = false
    private var inAudienceRestriction = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""

        switch localName {
        case "NameID":
            nameIDFormat = attributes["Format"]
        case "AuthnStatement":
            sessionNotOnOrAfter = attributes["SessionNotOnOrAfter"]
        case "Conditions":
            notBefore = attributes["NotBefore"]
            notOnOrAfter = attributes["NotOnOrAfter"]
        case "AudienceRestriction":
            inAudienceRestriction = true
        case "Response":
            destination = attributes["Destination"]
        case "Attribute":
            currentAttributeName = attributes["Name"]
            currentAttributeValues = []
        case "AttributeValue":
            inAttributeValue = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)

        switch localName {
        case "Issuer":
            if issuer == nil { issuer = text }
        case "NameID":
            if nameID == nil { nameID = text }
        case "Audience":
            if inAudienceRestriction && !text.isEmpty { audiences.append(text) }
        case "AudienceRestriction":
            inAudienceRestriction = false
        case "AttributeValue":
            if !text.isEmpty { currentAttributeValues.append(text) }
            inAttributeValue = false
        case "Attribute":
            if let name = currentAttributeName, !currentAttributeValues.isEmpty {
                self.attributes[name] = currentAttributeValues
            }
            currentAttributeName = nil
        default:
            break
        }
        currentText = ""
    }
}

/// Parses XML signature elements to extract SignatureValue.
private final class SignatureXMLParserDelegate: NSObject, XMLParserDelegate {
    var signatureValue: String?
    private var currentElement: String?
    private var currentText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName
        currentText = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "SignatureValue" {
            signatureValue = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentText = ""
    }
}

// MARK: - Errors

public enum SAMLError: Error, LocalizedError, Sendable {
    case invalidCertificate
    case malformedResponse
    case issuerMismatch
    case assertionExpired
    case conditionNotYetValid
    case audienceMismatch
    case destinationMismatch
    case signatureVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCertificate: "Invalid IdP X.509 certificate"
        case .malformedResponse: "Malformed SAML Response"
        case .issuerMismatch: "SAML assertion issuer does not match configured IdP"
        case .assertionExpired: "SAML assertion has expired (NotOnOrAfter)"
        case .conditionNotYetValid: "SAML assertion is not yet valid (NotBefore)"
        case .audienceMismatch: "SAML AudienceRestriction does not match configured audience"
        case .destinationMismatch: "SAML Response Destination does not match configured endpoint"
        case .signatureVerificationFailed: "SAML XML signature verification failed"
        }
    }
}
