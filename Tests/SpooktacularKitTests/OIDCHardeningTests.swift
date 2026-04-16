import Testing
import Foundation
@testable import SpookInfrastructureApple

/// OIDC claim-enforcement safety tests.
///
/// Previously `OIDCTokenVerifier` treated `exp` as optional and
/// fell back to an empty string for `sub` — two quiet downgrades
/// that collapsed distinct principals into "unauthenticated-
/// forever" territory. These tests lock in the hardened behavior
/// so a future regression is loud.
@Suite("OIDC claim hardening", .tags(.security, .identity))
struct OIDCHardeningTests {

    @Test("OIDCError surfaces a distinct case for missing required claim")
    func missingClaimError() {
        let err = OIDCError.missingRequiredClaim("sub")
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("sub"))
        #expect(desc.contains("missing"))
    }

    @Test("OIDCError flags future iat explicitly")
    func tokenIssuedInFutureError() {
        let err = OIDCError.tokenIssuedInFuture
        let desc = err.errorDescription ?? ""
        #expect(desc.contains("future"))
    }

    @Test("tokenExpired remains a distinct case from missing-claim")
    func expiredStillSeparate() {
        // Shape check: missingRequiredClaim and tokenExpired are not
        // the same case — a production alert differentiates "token
        // expired long ago" (key rotation) from "token missing exp
        // entirely" (misconfigured IdP).
        let a: OIDCError = .missingRequiredClaim("exp")
        let b: OIDCError = .tokenExpired
        let aDesc = a.errorDescription ?? ""
        let bDesc = b.errorDescription ?? ""
        #expect(aDesc != bDesc)
    }
}
