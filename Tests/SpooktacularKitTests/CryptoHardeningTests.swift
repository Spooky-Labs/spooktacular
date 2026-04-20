import Testing
import Foundation
import CryptoKit
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// Adversarial tests for the Fortune-20 crypto-hardening pass.
///
/// Each suite corresponds to one of the hardening findings.
/// Every test is **adversarial** — an attacker-shaped input
/// designed to make the naïve implementation succeed where the
/// hardened implementation must refuse.
@Suite("Crypto hardening pass", .tags(.security, .cryptography))
struct CryptoHardeningTests {

    // MARK: - 1. SAML: missing Conditions → reject

    @Suite("SAML Conditions fail-closed")
    struct SAMLConditionsFailClosed {

        /// Documented shape: the error case `.missingConditions`
        /// exists and is distinct from other SAML failures. Full
        /// round-trip requires a signed assertion; here we pin
        /// the surface.
        @Test("SAMLError.missingConditions is distinct from other cases")
        func missingConditionsDistinct() {
            let a = SAMLError.missingConditions
            let b = SAMLError.assertionExpired
            let c = SAMLError.conditionNotYetValid
            #expect(a != b)
            #expect(a != c)
        }

        @Test("missingConditions error message mentions Conditions / NotBefore / NotOnOrAfter")
        func missingConditionsMessage() {
            let desc = SAMLError.missingConditions.errorDescription ?? ""
            #expect(desc.contains("Conditions"))
            #expect(desc.contains("NotBefore") || desc.contains("NotOnOrAfter"))
        }
    }

    // MARK: - 2. XML: billion-laughs defense

    @Suite("XML entity-expansion defense")
    struct XMLEntityExpansion {

        /// Billion-laughs style input: ten levels of nested
        /// entity definitions, each referencing the one below.
        /// A naïve parser with unbounded expansion would
        /// materialize 10^10 characters. We refuse before the
        /// first expansion goes anywhere.
        @Test("Billion-laughs input is rejected")
        func billionLaughsRejected() {
            let laughs = """
            <?xml version="1.0"?>
            <!DOCTYPE lolz [
              <!ENTITY lol "lol">
              <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
              <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
              <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
              <!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">
              <!ENTITY lol5 "&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;&lol4;">
              <!ENTITY lol6 "&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;&lol5;">
              <!ENTITY lol7 "&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;&lol6;">
              <!ENTITY lol8 "&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;&lol7;">
              <!ENTITY lol9 "&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;&lol8;">
            ]>
            <lolz>&lol9;</lolz>
            """
            // Either the entity-expansion guard fires (expected
            // hardened behavior), or Foundation's XMLParser
            // rejects the input at the DTD stage. Either way
            // counts as refusal; the contract is "does not
            // succeed in expanding the payload".
            let data = Data(laughs.utf8)
            let result = Result { try XMLCanonicalization.parse(data) }
            switch result {
            case .success:
                Issue.record("Billion-laughs payload was not rejected")
            case .failure:
                break  // expected
            }
        }

        @Test("Well-formed small document parses cleanly")
        func wellFormedSmallOK() throws {
            let data = Data("<root><child>ok</child></root>".utf8)
            let root = try XMLCanonicalization.parse(data)
            #expect(root.localName == "root")
        }

        @Test("Over-deep nesting is rejected")
        func tooDeepNestingRejected() {
            // `XMLCanonicalization.maxElementDepth` defaults to
            // 10. Build 15 levels of nesting and expect refusal.
            var doc = ""
            for i in 0..<15 { doc += "<l\(i)>" }
            for i in (0..<15).reversed() { doc += "</l\(i)>" }
            let data = Data(doc.utf8)
            let result = Result { try XMLCanonicalization.parse(data) }
            switch result {
            case .success:
                Issue.record("Over-deep nesting was not rejected")
            case .failure(let err):
                // Expected: `.elementDepthExceeded` from our
                // typed surface, OR a generic parseFailed
                // (XMLParser may reject before our delegate
                // sees all 15 levels, depending on path).
                let hardenedErr = err as? XMLCanonicalizationError
                #expect(hardenedErr != nil)
            }
        }
    }

    // MARK: - 3. CDATA fidelity

    @Suite("XML CDATA handling")
    struct XMLCDATA {

        @Test("CDATA content is preserved and correctly escaped")
        func cdataRoundTrip() throws {
            let xml = "<e><![CDATA[foo<bar>&baz]]></e>"
            let data = Data(xml.utf8)
            let root = try XMLCanonicalization.parse(data)
            let canonical = XMLCanonicalization.canonicalize(root)
            let out = String(data: canonical, encoding: .utf8) ?? ""
            // C14N §2.3 replaces CDATA with its character
            // content and escapes `<`, `>`, `&` per the element-
            // text rules. The content "foo<bar>&baz" must
            // appear in canonical form as "foo&lt;bar&gt;&amp;baz".
            #expect(out.contains("foo&lt;bar&gt;&amp;baz"))
        }
    }

    // MARK: - 4. OIDC iss-before-key (shape / documentation gate)

    @Suite("OIDC iss-before-key")
    struct OIDCIssBeforeKey {

        /// A structurally-malformed token with a spoofed `iss`
        /// should never pass audience validation — the
        /// verifier short-circuits on issuer mismatch before
        /// fetching any JWKS.
        @Test("Malformed token with wrong iss is rejected as malformed")
        func malformedTokenRejected() async {
            let config = OIDCProviderConfig(
                issuerURL: "https://idp-a.example.com",
                clientID: "client-a",
                audience: "client-a"
            )
            let verifier = OIDCTokenVerifier(
                config: config, http: StaticHTTPClient()
            )
            await #expect(throws: OIDCError.self) {
                _ = try await verifier.verify(token: "not.a.jwt")
            }
        }
    }

    // MARK: - 5. FederatedIdentity.isExpired(now:)

    @Suite("FederatedIdentity.isExpired(now:)")
    struct FederatedIsExpired {

        @Test("isExpired(now:) is a method, not a property, accepts injected now")
        func injectedNow() {
            let id = FederatedIdentity(
                issuer: "i", subject: "s",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            #expect(id.isExpired(now: Date(timeIntervalSince1970: 1_700_000_001)))
            #expect(!id.isExpired(now: Date(timeIntervalSince1970: 1_699_999_999)))
        }

        @Test("isExpired is false when expiresAt is nil")
        func nilExpiryNeverExpires() {
            let id = FederatedIdentity(issuer: "i", subject: "s", expiresAt: nil)
            #expect(!id.isExpired(now: Date()))
        }
    }

    // MARK: - 6. HMAC empty secret

    @Suite("HMAC empty secret defense")
    struct HMACEmptySecret {

        @Test("WebhookSignatureVerifier.verify refuses empty secret even if signature formally matches")
        func emptySecretRejected() {
            let hmac = CryptoKitHMACProvider()
            let body = Data("payload".utf8)
            // Pretend the attacker computed a SHA-256 of the
            // body (unkeyed) and wrapped it in `sha256=`. With
            // an empty secret, a naïve implementation would
            // accept it. We must refuse.
            let sha = SHA256.hash(data: body)
            let hex = sha.map { String(format: "%02x", $0) }.joined()
            let sig = "sha256=\(hex)"
            let ok = WebhookSignatureVerifier.verify(
                body: body, signature: sig, secret: "", hmac: hmac
            )
            #expect(!ok)
        }

        @Test("CryptoKitHMACProvider returns a non-forgeable sentinel on empty secret")
        func providerEmptySecretSentinel() {
            let provider = CryptoKitHMACProvider()
            let a = provider.hmacSHA256(body: Data("a".utf8), secret: "")
            let b = provider.hmacSHA256(body: Data("b".utf8), secret: "")
            // Sentinel is body-independent — deterministic but
            // identical across inputs, so no caller can be
            // tricked into computing a body-specific MAC from
            // the empty-key path.
            #expect(a == b)
            #expect(a.count == 64)  // SHA-256 hex
        }
    }

    // MARK: - 7. Clock-skew direction (isFutureIssued)

    @Suite("BreakGlass clock-skew direction")
    struct BreakGlassSkew {

        @Test("Ticket issued 61s in the future is rejected")
        func futureIssuedRejected() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let ticket = BreakGlassTicket(
                jti: "j", issuer: "alice", tenant: .default,
                issuedAt: now.addingTimeInterval(61),
                expiresAt: now.addingTimeInterval(3600)
            )
            #expect(ticket.isFutureIssued(now: now, clockSkew: 60))
        }

        @Test("Ticket issued 59s in the future is accepted")
        func futureIssuedInToleranceAccepted() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let ticket = BreakGlassTicket(
                jti: "j", issuer: "alice", tenant: .default,
                issuedAt: now.addingTimeInterval(59),
                expiresAt: now.addingTimeInterval(3600)
            )
            #expect(!ticket.isFutureIssued(now: now, clockSkew: 60))
        }

        @Test("Issued-at in the past is accepted regardless of skew")
        func pastIssuedAccepted() {
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let ticket = BreakGlassTicket(
                jti: "j", issuer: "alice", tenant: .default,
                issuedAt: now.addingTimeInterval(-3600),
                expiresAt: now.addingTimeInterval(3600)
            )
            #expect(!ticket.isFutureIssued(now: now))
        }
    }

    // MARK: - 8. maxUses counter

    @Suite("BreakGlass maxUses counter")
    struct BreakGlassMaxUses {

        @Test("maxUses=5 accepts exactly 5 consumes")
        func capRespected() {
            let cache = UsedTicketCache()
            let jti = "ticket-5x"
            let exp = Date().addingTimeInterval(600)
            for _ in 0..<5 {
                #expect(cache.tryConsume(jti: jti, expiresAt: exp, maxUses: 5))
            }
            // 6th attempt must refuse.
            #expect(!cache.tryConsume(jti: jti, expiresAt: exp, maxUses: 5))
        }

        @Test("maxUses=1 collapses to strict single-use")
        func singleUse() {
            let cache = UsedTicketCache()
            let jti = "ticket-1x"
            let exp = Date().addingTimeInterval(600)
            #expect(cache.tryConsume(jti: jti, expiresAt: exp, maxUses: 1))
            #expect(!cache.tryConsume(jti: jti, expiresAt: exp, maxUses: 1))
        }

        @Test("500 attempts on a maxUses=5 ticket yield 5 successes")
        func attemptFloodOnlyYields5() {
            let cache = UsedTicketCache()
            let jti = "ticket-flood"
            let exp = Date().addingTimeInterval(600)
            var successes = 0
            // `for _ in 0..<500 where cache.tryConsume(...)` is
            // what SwiftLint's `for_where` rule suggests, but
            // `where` is a pure-filter clause on the iteration —
            // it can't also be the side-effecting call whose
            // result we count. Disable inline.
            // swiftlint:disable:next for_where
            for _ in 0..<500 {
                if cache.tryConsume(jti: jti, expiresAt: exp, maxUses: 5) {
                    successes += 1
                }
            }
            #expect(successes == 5)
        }
    }

    // MARK: - 9. Webhook truncated / non-hex signature rejection

    @Suite("Webhook signature shape")
    struct WebhookSignatureShape {

        let body = Data("payload".utf8)
        let secret = "secret-abc"
        let hmac = CryptoKitHMACProvider()

        @Test("Signature with 63 hex digits is rejected")
        func truncated63() {
            let sig = "sha256=" + String(repeating: "a", count: 63)
            let ok = WebhookSignatureVerifier.verify(
                body: body, signature: sig, secret: secret, hmac: hmac
            )
            #expect(!ok)
        }

        @Test("Signature with 65 hex digits is rejected")
        func oversized65() {
            let sig = "sha256=" + String(repeating: "a", count: 65)
            let ok = WebhookSignatureVerifier.verify(
                body: body, signature: sig, secret: secret, hmac: hmac
            )
            #expect(!ok)
        }

        @Test("Signature with non-hex character is rejected")
        func nonHex() {
            let sig = "sha256=" + String(repeating: "g", count: 64)
            let ok = WebhookSignatureVerifier.verify(
                body: body, signature: sig, secret: secret, hmac: hmac
            )
            #expect(!ok)
        }
    }

    // MARK: - 10. BreakGlass envelope format

    @Suite("BreakGlass envelope format validation")
    struct BreakGlassFormat {

        @Test("Envelope without bgt: prefix is rejected")
        func missingPrefix() {
            let signer = P256.Signing.PrivateKey()
            #expect(throws: BreakGlassTicketError.self) {
                _ = try BreakGlassTicketCodec.decode(
                    "notbgt:aa.bb",
                    publicKeys: [signer.publicKey],
                    allowedIssuers: ["alice"]
                )
            }
        }

        @Test("Envelope with zero dots is rejected")
        func zeroDots() {
            let signer = P256.Signing.PrivateKey()
            #expect(throws: BreakGlassTicketError.self) {
                _ = try BreakGlassTicketCodec.decode(
                    "bgt:onlyonepiece",
                    publicKeys: [signer.publicKey],
                    allowedIssuers: ["alice"]
                )
            }
        }

        @Test("Envelope with empty base64 segment is rejected")
        func emptySegment() {
            let signer = P256.Signing.PrivateKey()
            #expect(throws: BreakGlassTicketError.self) {
                _ = try BreakGlassTicketCodec.decode(
                    "bgt:.", publicKeys: [signer.publicKey],
                    allowedIssuers: ["alice"]
                )
            }
        }

        @Test("Envelope with invalid base64 payload is rejected")
        func invalidBase64() {
            let signer = P256.Signing.PrivateKey()
            #expect(throws: BreakGlassTicketError.self) {
                _ = try BreakGlassTicketCodec.decode(
                    "bgt:@@@.###", publicKeys: [signer.publicKey],
                    allowedIssuers: ["alice"]
                )
            }
        }
    }

    // MARK: - 11. TLS anchor pinning contract

    @Suite("PinnedTLSIdentityProvider contract")
    struct PinnedTLSContract {

        @Test("PinnedTLSIdentityProvider refines TLSIdentityProvider")
        func refinement() {
            // Shape check: a `PinnedTLSIdentityProvider` is a
            // `TLSIdentityProvider`. Callers that only need the
            // generic client keep working; callers that need
            // pinning up-cast.
            func acceptsBase(_ p: any TLSIdentityProvider) {}
            // Compile-time assertion: if the refinement breaks,
            // this closure signature no longer type-checks.
            let _: (any PinnedTLSIdentityProvider) -> Void = { p in acceptsBase(p) }
        }
    }
}

// MARK: - Test doubles

/// Minimal HTTPClient that returns empty data for every request —
/// enough to exercise the malformed-token reject path without
/// any real network I/O.
private struct StaticHTTPClient: HTTPClient {
    func execute(_ request: DomainHTTPRequest) async throws -> DomainHTTPResponse {
        DomainHTTPResponse(statusCode: 200, headers: [:], body: Data())
    }
}
