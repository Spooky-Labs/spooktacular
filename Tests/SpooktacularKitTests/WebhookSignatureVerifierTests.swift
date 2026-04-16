import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("Webhook Signature Verifier", .tags(.security, .cryptography))
struct WebhookSignatureVerifierTests {

    let secret = "test-webhook-secret"
    let body = Data("{\"action\":\"completed\"}".utf8)
    let hmac = CryptoKitHMACProvider()

    // MARK: - Verification Scenarios

    @Suite("Signature Verification")
    struct SignatureVerification {

        let secret = "test-webhook-secret"
        let body = Data("{\"action\":\"completed\"}".utf8)
        let hmac = CryptoKitHMACProvider()

        /// Describes a webhook verification scenario for parameterized testing.
        struct VerificationCase: CustomTestStringConvertible, Sendable {
            let label: String
            let signatureProvider: @Sendable (Data, String, CryptoKitHMACProvider) -> String
            let expected: Bool

            var testDescription: String { label }

            /// Valid signature: compute and prefix with sha256=.
            static let valid = VerificationCase(
                label: "valid signature passes",
                signatureProvider: { body, secret, hmac in
                    "sha256=\(WebhookSignatureVerifier.sign(body: body, secret: secret, hmac: hmac))"
                },
                expected: true
            )

            /// Wrong signature: bogus hex after sha256=.
            static let wrong = VerificationCase(
                label: "wrong signature rejects",
                signatureProvider: { _, _, _ in "sha256=deadbeef" },
                expected: false
            )

            /// Missing prefix: valid HMAC but no sha256= prefix.
            static let missingPrefix = VerificationCase(
                label: "missing sha256= prefix rejects",
                signatureProvider: { body, secret, hmac in
                    WebhookSignatureVerifier.sign(body: body, secret: secret, hmac: hmac)
                },
                expected: false
            )

            /// Empty signature string.
            static let empty = VerificationCase(
                label: "empty signature rejects",
                signatureProvider: { _, _, _ in "" },
                expected: false
            )
        }

        @Test("verification produces correct result", arguments: [
            VerificationCase.valid,
            VerificationCase.wrong,
            VerificationCase.missingPrefix,
            VerificationCase.empty,
        ])
        func verification(scenario: VerificationCase) {
            let signature = scenario.signatureProvider(body, secret, hmac)
            let result = WebhookSignatureVerifier.verify(
                body: body, signature: signature, secret: secret, hmac: hmac
            )
            #expect(result == scenario.expected)
        }
    }

    // MARK: - Edge Cases

    @Suite("Edge Cases")
    struct EdgeCases {

        let secret = "test-webhook-secret"
        let hmac = CryptoKitHMACProvider()

        @Test("empty body with valid signature passes")
        func emptyBodyValid() {
            let empty = Data()
            let sig = WebhookSignatureVerifier.sign(body: empty, secret: secret, hmac: hmac)
            #expect(WebhookSignatureVerifier.verify(
                body: empty, signature: "sha256=\(sig)", secret: secret, hmac: hmac
            ))
        }

        @Test("different secrets produce different signatures")
        func differentSecretsProduceDifferentSignatures() {
            let body = Data("payload".utf8)
            let sig1 = WebhookSignatureVerifier.sign(body: body, secret: "secret-a", hmac: hmac)
            let sig2 = WebhookSignatureVerifier.sign(body: body, secret: "secret-b", hmac: hmac)
            #expect(sig1 != sig2)
        }

        @Test("different bodies produce different signatures")
        func differentBodiesProduceDifferentSignatures() {
            let body1 = Data("payload-1".utf8)
            let body2 = Data("payload-2".utf8)
            let sig1 = WebhookSignatureVerifier.sign(body: body1, secret: secret, hmac: hmac)
            let sig2 = WebhookSignatureVerifier.sign(body: body2, secret: secret, hmac: hmac)
            #expect(sig1 != sig2)
        }
    }

    // MARK: - Signing

    @Test("sign produces a consistent hex digest")
    func signConsistency() {
        let sig1 = WebhookSignatureVerifier.sign(body: body, secret: secret, hmac: hmac)
        let sig2 = WebhookSignatureVerifier.sign(body: body, secret: secret, hmac: hmac)
        #expect(sig1 == sig2)
        #expect(!sig1.isEmpty)
    }
}
