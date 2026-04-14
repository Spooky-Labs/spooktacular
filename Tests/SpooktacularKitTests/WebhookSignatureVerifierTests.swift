import Testing
import Foundation
@testable import SpooktacularKit

@Suite("WebhookSignatureVerifier")
struct WebhookSignatureVerifierTests {

    let secret = "test-webhook-secret"
    let body = Data("{\"action\":\"completed\"}".utf8)

    @Test("Valid signature passes")
    func validSignature() {
        let sig = WebhookSignatureVerifier.sign(body: body, secret: secret)
        #expect(WebhookSignatureVerifier.verify(body: body, signature: "sha256=\(sig)", secret: secret))
    }

    @Test("Wrong signature rejects")
    func wrongSignature() {
        #expect(!WebhookSignatureVerifier.verify(body: body, signature: "sha256=deadbeef", secret: secret))
    }

    @Test("Missing sha256= prefix rejects")
    func missingPrefix() {
        let sig = WebhookSignatureVerifier.sign(body: body, secret: secret)
        #expect(!WebhookSignatureVerifier.verify(body: body, signature: sig, secret: secret))
    }

    @Test("Empty body with valid signature passes")
    func emptyBody() {
        let empty = Data()
        let sig = WebhookSignatureVerifier.sign(body: empty, secret: secret)
        #expect(WebhookSignatureVerifier.verify(body: empty, signature: "sha256=\(sig)", secret: secret))
    }

    @Test("Empty signature rejects")
    func emptySignature() {
        #expect(!WebhookSignatureVerifier.verify(body: body, signature: "", secret: secret))
    }
}
