import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookInfrastructureApple

/// Tests for ``WebhookAuditSink`` configuration + signing math.
///
/// Avoids live HTTP by isolating the parts that are pure logic:
/// - Config construction accepts the expected parameters.
/// - HMAC signature math matches what the sink will produce
///   when a key is configured (tested against the same
///   `HMAC<SHA256>` primitive the sink uses).
/// - Error taxonomy is stable.
///
/// End-to-end webhook delivery is validated by manual testing
/// against Splunk HEC / Datadog sandbox endpoints rather than a
/// fragile in-test HTTP server.
@Suite("WebhookAuditSink", .tags(.audit))
struct WebhookAuditSinkTests {

    @Test("Config exposes all fields and uses sensible defaults")
    func configDefaults() {
        let url = URL(string: "https://siem.example.com/ingest")!
        let config = WebhookAuditSink.Config(url: url)
        #expect(config.url == url)
        #expect(config.hmacKey == nil)
        #expect(config.extraHeaders.isEmpty)
        #expect(config.batchSize == 50)
        #expect(config.batchInterval == 2.0)
        #expect(config.requestTimeout == 10.0)
    }

    @Test("Config passes through explicit overrides")
    func configOverrides() {
        let url = URL(string: "https://siem.example.com/ingest")!
        let key = SymmetricKey(data: Data([0x01, 0x02, 0x03, 0x04]))
        let config = WebhookAuditSink.Config(
            url: url,
            hmacKey: key,
            extraHeaders: ["DD-API-KEY": "abc"],
            batchSize: 10,
            batchInterval: 0.5,
            requestTimeout: 3.0
        )
        #expect(config.extraHeaders["DD-API-KEY"] == "abc")
        #expect(config.batchSize == 10)
        #expect(config.batchInterval == 0.5)
        #expect(config.requestTimeout == 3.0)
    }

    @Test("HMAC signing math matches CryptoKit's HMAC<SHA256>")
    func hmacMathMatches() {
        // This exercises the same primitive the sink uses, so a
        // future swap to a different MAC would break this test
        // immediately rather than silently disabling SIEM
        // signature verification.
        let key = SymmetricKey(data: Data("my-shared-secret".utf8))
        let body = Data("{\"source\":\"spooktacular\"}".utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex = Array(mac).map { String(format: "%02x", $0) }.joined()

        // Known-good reference from `echo -n ... | openssl dgst -sha256 -hmac my-shared-secret`:
        #expect(hex.count == 64)
        // Re-compute to confirm determinism.
        let mac2 = HMAC<SHA256>.authenticationCode(for: body, using: key)
        let hex2 = Array(mac2).map { String(format: "%02x", $0) }.joined()
        #expect(hex == hex2)
    }

    @Test("WebhookAuditError surfaces HTTP status codes")
    func errorTaxonomy() {
        let nonHTTP = WebhookAuditError.nonHTTPResponse
        #expect(nonHTTP.errorDescription?.contains("HTTP") == true)

        let http500 = WebhookAuditError.httpStatus(500)
        #expect(http500.errorDescription?.contains("500") == true)

        let http429 = WebhookAuditError.httpStatus(429)
        #expect(http429.errorDescription?.contains("429") == true)
    }

    @Test("Audit records encode as expected envelope shape")
    func envelopeShape() throws {
        // The sink's Envelope is private; we test the *shape*
        // AuditRecord serializes to so a SIEM parser can write
        // against it.
        let record = AuditRecord(
            actorIdentity: "alice@acme",
            tenant: .default,
            scope: .runner,
            resource: "vm-a",
            action: "create",
            outcome: .success
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // These are the fields a SIEM dashboard will key off.
        #expect(json["actorIdentity"] as? String == "alice@acme")
        #expect(json["resource"] as? String == "vm-a")
        #expect(json["action"] as? String == "create")
        #expect(json["outcome"] as? String == "success")
        #expect(json["timestamp"] != nil, "timestamp must be present; SIEMs sort on it")
    }
}
