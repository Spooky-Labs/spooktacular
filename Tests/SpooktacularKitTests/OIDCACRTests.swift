import Testing
import Foundation
@testable import SpookCore
@testable import SpookInfrastructureApple

/// Tests for the OIDC Authentication Context Class Reference
/// (`acr`) enforcement path added to satisfy OWASP ASVS V2.7 and
/// V4.3.1 — per-action MFA on federated admin tokens.
///
/// Rather than stand up a full signed JWT + mock JWKS (that plumbing
/// belongs in an integration test), these tests pin the surface
/// that matters to an auditor:
///
/// - `OIDCProviderConfig.requiredACRValues` survives Codable
///   round-trips, so operator config can pin an allowlist.
/// - The `insufficientACR` error surfaces the required set and the
///   received value distinctly, so an operator-visible log line
///   tells them exactly what the IdP emitted vs. what was expected.
/// - The error case is distinct from every other OIDC failure mode
///   — a monitoring query looking for "stepped-up MFA required"
///   won't get lost in `tokenExpired` or `audienceMismatch` noise.
@Suite("OIDC acr enforcement", .tags(.security, .identity))
struct OIDCACRTests {

    @Test("OIDCProviderConfig.requiredACRValues round-trips through Codable")
    func configCodableRoundTrip() throws {
        let config = OIDCProviderConfig(
            issuerURL: "https://idp.example.com",
            clientID: "spook-control-plane",
            audience: "spook-control-plane",
            requiredACRValues: [
                "http://schemas.openid.net/pape/policies/2007/06/multi-factor",
                "urn:mace:incommon:iap:silver"
            ]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OIDCProviderConfig.self, from: data)
        #expect(decoded.requiredACRValues?.count == 2)
        #expect(decoded.requiredACRValues?.contains("urn:mace:incommon:iap:silver") == true)
    }

    @Test("requiredACRValues defaults to nil when omitted")
    func requiredACRValuesDefaultsToNil() {
        let config = OIDCProviderConfig(
            issuerURL: "https://idp.example.com",
            clientID: "spook-control-plane",
            audience: "spook-control-plane"
        )
        #expect(config.requiredACRValues == nil)
    }

    @Test("insufficientACR surfaces both required set and received value")
    func insufficientACRMessages() {
        let err = OIDCError.insufficientACR(
            required: ["urn:mace:incommon:iap:silver"],
            received: "urn:mace:incommon:iap:bronze"
        )
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("bronze"))
        #expect(desc.contains("silver"))
    }

    @Test("insufficientACR with missing claim distinguishes '(missing)'")
    func insufficientACRWithMissingClaim() {
        let err = OIDCError.insufficientACR(
            required: ["http://schemas.openid.net/pape/policies/2007/06/multi-factor"],
            received: nil
        )
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("missing"))
    }

    @Test("insufficientACR recovery text mentions IdP configuration")
    func insufficientACRRecoverySuggestion() {
        let err = OIDCError.insufficientACR(required: ["x"], received: "y")
        let hint = err.recoverySuggestion ?? ""
        #expect(hint.contains("IdP") || hint.contains("MFA"))
    }

    @Test("insufficientACR is distinct from other auth failures")
    func distinctFromOtherErrors() {
        let acrErr: OIDCError = .insufficientACR(required: ["x"], received: nil)
        let audErr: OIDCError = .audienceMismatch
        let expErr: OIDCError = .tokenExpired
        #expect(acrErr.errorDescription != audErr.errorDescription)
        #expect(acrErr.errorDescription != expErr.errorDescription)
    }
}
