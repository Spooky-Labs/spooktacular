import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

@Suite("SAMLVerifier")
struct SAMLVerifierTests {
    @Test("SAMLAssertion converts to FederatedIdentity")
    func assertionToIdentity() {
        let assertion = SAMLAssertion(
            issuer: "https://idp.example.com",
            nameID: "user@example.com",
            nameIDFormat: "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
            attributes: ["groups": ["admins", "developers"], "displayName": ["Jane Doe"]]
        )
        let identity = assertion.toFederatedIdentity()
        #expect(identity.issuer == "https://idp.example.com")
        #expect(identity.subject == "user@example.com")
        #expect(identity.email == "user@example.com")
        #expect(identity.groups == ["admins", "developers"])
        #expect(identity.displayName == "Jane Doe")
    }

    @Test("SAMLAssertion expiry detection")
    func assertionExpiry() {
        let expired = SAMLAssertion(issuer: "i", nameID: "n", sessionExpiresAt: Date.distantPast)
        let valid = SAMLAssertion(issuer: "i", nameID: "n", sessionExpiresAt: Date.distantFuture)
        #expect(expired.isExpired)
        #expect(!valid.isExpired)
    }

    @Test("SAMLProviderConfig encodes and decodes")
    func configCodable() throws {
        let config = SAMLProviderConfig(
            entityID: "https://idp.example.com",
            ssoURL: "https://idp.example.com/sso",
            certificate: "base64cert"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(SAMLProviderConfig.self, from: data)
        #expect(decoded.entityID == "https://idp.example.com")
    }

    @Test("SAMLError has descriptions")
    func errorDescriptions() {
        let errors: [SAMLError] = [.invalidCertificate, .malformedResponse, .issuerMismatch, .assertionExpired, .signatureVerificationFailed]
        for error in errors {
            #expect(error.errorDescription != nil)
        }
    }

}
