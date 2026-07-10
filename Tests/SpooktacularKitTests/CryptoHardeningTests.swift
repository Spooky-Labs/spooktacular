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

    // MARK: - 7. Webhook truncated / non-hex signature rejection

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

    // MARK: - 8. TLS anchor pinning contract

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
