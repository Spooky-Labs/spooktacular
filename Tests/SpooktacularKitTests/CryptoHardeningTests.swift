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
            // Map each attempt to a Bool via `reduce` — filter
            // discipline SwiftLint's `for_where` rule wants, but
            // counting the side-effecting call's `true` results
            // without the for/if shape the rule rejects.
            let successes = (0..<500).reduce(into: 0) { count, _ in
                if cache.tryConsume(jti: jti, expiresAt: exp, maxUses: 5) {
                    count += 1
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
