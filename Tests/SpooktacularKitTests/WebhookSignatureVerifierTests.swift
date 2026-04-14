import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("WebhookSignatureVerifier")
struct WebhookSignatureVerifierTests {

    let secret = "test-webhook-secret"
    let body = Data("{\"action\":\"completed\"}".utf8)
    let hmac = CryptoKitHMACProvider()

    @Test("Valid signature passes")
    func validSignature() {
        let sig = WebhookSignatureVerifier.sign(body: body, secret: secret, hmac: hmac)
        #expect(WebhookSignatureVerifier.verify(body: body, signature: "sha256=\(sig)", secret: secret, hmac: hmac))
    }

    @Test("Wrong signature rejects")
    func wrongSignature() {
        #expect(!WebhookSignatureVerifier.verify(body: body, signature: "sha256=deadbeef", secret: secret, hmac: hmac))
    }

    @Test("Missing sha256= prefix rejects")
    func missingPrefix() {
        let sig = WebhookSignatureVerifier.sign(body: body, secret: secret, hmac: hmac)
        #expect(!WebhookSignatureVerifier.verify(body: body, signature: sig, secret: secret, hmac: hmac))
    }

    @Test("Empty body with valid signature passes")
    func emptyBody() {
        let empty = Data()
        let sig = WebhookSignatureVerifier.sign(body: empty, secret: secret, hmac: hmac)
        #expect(WebhookSignatureVerifier.verify(body: empty, signature: "sha256=\(sig)", secret: secret, hmac: hmac))
    }

    @Test("Empty signature rejects")
    func emptySignature() {
        #expect(!WebhookSignatureVerifier.verify(body: body, signature: "", secret: secret, hmac: hmac))
    }
}
