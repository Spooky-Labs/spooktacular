import Foundation
import Security
import SpookCore
import SpookApplication

/// Verifies SAML Response XML and extracts assertions.
///
/// Uses Security.framework for X.509 certificate parsing and
/// XML signature verification.
public actor SAMLAssertionVerifier: FederatedIdentityVerifier {
    private let config: SAMLProviderConfig
    private let idpCertificate: SecCertificate

    public init(config: SAMLProviderConfig) throws {
        self.config = config
        // Parse the IdP's X.509 certificate from base64
        guard let certData = Data(base64Encoded: config.certificate),
              let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw SAMLError.invalidCertificate
        }
        self.idpCertificate = cert
    }

    /// Verifies a base64-encoded SAML Response and extracts the identity.
    public func verify(token: String) async throws -> FederatedIdentity {
        // 1. Base64 decode the SAML Response
        guard let responseData = Data(base64Encoded: token),
              let responseXML = String(data: responseData, encoding: .utf8) else {
            throw SAMLError.malformedResponse
        }

        // 2. Parse the XML to extract key fields
        let assertion = try parseAssertion(from: responseXML)

        // 3. Verify the issuer matches
        guard assertion.issuer == config.entityID else {
            throw SAMLError.issuerMismatch
        }

        // 4. Check expiry
        guard !assertion.isExpired else {
            throw SAMLError.assertionExpired
        }

        // 5. Verify XML signature
        try verifySignature(xml: responseXML)

        // 6. Convert to FederatedIdentity
        return assertion.toFederatedIdentity()
    }

    /// Parses a SAML assertion from XML using simple string extraction.
    /// For production, consider a proper XML parser.
    private func parseAssertion(from xml: String) throws -> SAMLAssertion {
        // Extract Issuer
        guard let issuer = extractElement("Issuer", from: xml) else {
            throw SAMLError.malformedResponse
        }

        // Extract NameID
        guard let nameID = extractElement("NameID", from: xml) else {
            throw SAMLError.malformedResponse
        }

        // Extract NameID Format attribute
        let nameIDFormat = extractAttribute("Format", fromElement: "NameID", in: xml)

        // Extract SessionNotOnOrAfter
        let sessionExpiry: Date?
        if let expiryStr = extractAttribute("SessionNotOnOrAfter", fromElement: "AuthnStatement", in: xml) {
            let formatter = ISO8601DateFormatter()
            sessionExpiry = formatter.date(from: expiryStr)
        } else {
            sessionExpiry = nil
        }

        // Extract Attributes
        var attributes: [String: [String]] = [:]
        let attrPattern = try NSRegularExpression(
            pattern: #"<(?:saml:)?Attribute\s+Name="([^"]+)"[^>]*>(.*?)</(?:saml:)?Attribute>"#,
            options: .dotMatchesLineSeparators
        )
        let valuePattern = try NSRegularExpression(
            pattern: #"<(?:saml:)?AttributeValue[^>]*>([^<]+)</(?:saml:)?AttributeValue>"#
        )

        let attrMatches = attrPattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
        for match in attrMatches {
            guard let nameRange = Range(match.range(at: 1), in: xml),
                  let bodyRange = Range(match.range(at: 2), in: xml) else { continue }
            let name = String(xml[nameRange])
            let body = String(xml[bodyRange])
            let valueMatches = valuePattern.matches(in: body, range: NSRange(body.startIndex..., in: body))
            let values = valueMatches.compactMap { m -> String? in
                guard let r = Range(m.range(at: 1), in: body) else { return nil }
                return String(body[r])
            }
            attributes[name] = values
        }

        return SAMLAssertion(
            issuer: issuer, nameID: nameID,
            nameIDFormat: nameIDFormat,
            sessionExpiresAt: sessionExpiry,
            attributes: attributes
        )
    }

    /// Verifies the XML signature using the IdP's X.509 certificate.
    private func verifySignature(xml: String) throws {
        // Extract the SignatureValue and SignedInfo from the XML
        guard let signatureB64 = extractElement("SignatureValue", from: xml),
              let signatureData = Data(base64Encoded: signatureB64.replacingOccurrences(
                  of: "\\s", with: "", options: .regularExpression
              )) else {
            throw SAMLError.signatureVerificationFailed
        }

        // Get the public key from the IdP certificate
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

        // Verify with RSA-SHA256
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

    private func extractElement(_ name: String, from xml: String) -> String? {
        let patterns = [
            "<\(name)[^>]*>([^<]+)</\(name)>",
            "<saml:\(name)[^>]*>([^<]+)</saml:\(name)>",
            "<saml2:\(name)[^>]*>([^<]+)</saml2:\(name)>",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range])
            }
        }
        return nil
    }

    private func extractAttribute(_ attr: String, fromElement element: String, in xml: String) -> String? {
        let patterns = [
            "<\(element)[^>]*\(attr)=\"([^\"]+)\"",
            "<saml:\(element)[^>]*\(attr)=\"([^\"]+)\"",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range])
            }
        }
        return nil
    }
}

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
