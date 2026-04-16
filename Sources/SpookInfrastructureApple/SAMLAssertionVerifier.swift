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

    public func verify(token: String) async throws -> FederatedIdentity {
        guard let responseData = Data(base64Encoded: token),
              let responseXML = String(data: responseData, encoding: .utf8) else {
            throw SAMLError.malformedResponse
        }

        let assertion = try parseAssertion(from: responseXML)

        guard assertion.issuer == config.entityID else {
            throw SAMLError.issuerMismatch
        }

        guard !assertion.isExpired else {
            throw SAMLError.assertionExpired
        }

        try verifySignature(xml: responseXML)

        return assertion.toFederatedIdentity()
    }

    // MARK: - XMLParser-Based Parsing

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

    private var currentElement: String?
    private var currentText = ""
    private var currentAttributeName: String?
    private var currentAttributeValues: [String] = []
    private var inAttributeValue = false

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
    case signatureVerificationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidCertificate: "Invalid IdP X.509 certificate"
        case .malformedResponse: "Malformed SAML Response"
        case .issuerMismatch: "SAML assertion issuer does not match configured IdP"
        case .assertionExpired: "SAML assertion has expired"
        case .signatureVerificationFailed: "SAML XML signature verification failed"
        }
    }
}
