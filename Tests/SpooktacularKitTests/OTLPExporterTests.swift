import Testing
import Foundation
@testable import SpooktacularApplication

/// Tests for ``OTelSpan`` + ``OTLPHTTPJSONExporter``'s body
/// construction. Live export is validated by pointing the
/// exporter at a real collector (Tempo / Honeycomb / Datadog)
/// in manual testing.
@Suite("OTLP exporter", .tags(.infrastructure))
struct OTLPExporterTests {

    @Test("Trace IDs are 32 hex chars (16 bytes)")
    func traceIDFormat() {
        for _ in 0..<16 {
            let id = OTelSpan.newTraceID()
            #expect(id.count == 32)
            #expect(id.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("Span IDs are 16 hex chars (8 bytes)")
    func spanIDFormat() {
        for _ in 0..<16 {
            let id = OTelSpan.newSpanID()
            #expect(id.count == 16)
            #expect(id.allSatisfy { $0.isHexDigit })
        }
    }

    @Test("Successive trace IDs are distinct with high probability")
    func traceIDDistinctness() {
        // 128 bits of randomness — collision probability is
        // effectively zero. A systematic bug (same seed) would
        // produce duplicates quickly.
        let ids = (0..<100).map { _ in OTelSpan.newTraceID() }
        #expect(Set(ids).count == 100)
    }

    @Test("AttributeValue OTLP encoding wraps each primitive with the right tag")
    func attributeValueEncoding() {
        #expect(String(describing: OTLPHTTPJSONExporter.otlpValue(.string("hi")))
            .contains("stringValue"))
        #expect(String(describing: OTLPHTTPJSONExporter.otlpValue(.int(42)))
            .contains("intValue"))
        #expect(String(describing: OTLPHTTPJSONExporter.otlpValue(.bool(true)))
            .contains("boolValue"))
        #expect(String(describing: OTLPHTTPJSONExporter.otlpValue(.double(1.5)))
            .contains("doubleValue"))
    }

    @Test("int attribute is stringified on the wire (OTLP-JSON spec)")
    func intIsStringified() {
        // OTLP-JSON requires int64 to be encoded as a string to
        // avoid JSON number-precision issues. This test catches
        // regressions where someone "fixes" the encoding to emit
        // a raw int.
        let value = OTLPHTTPJSONExporter.otlpValue(.int(9_999_999_999))
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"9999999999\""))
    }

    @Test("Exporter increments MetricsCollector.recordOTLPFailure on transport failure")
    func recordsFailureMetric() async throws {
        // Point the exporter at an unroutable address so the POST
        // fails synchronously without a collector needing to be up.
        // `127.0.0.1:1` is an unused-by-convention port.
        let endpoint = try #require(URL(string: "http://127.0.0.1:1/v1/traces"))
        let metrics = MetricsCollector()
        let exporter = OTLPHTTPJSONExporter(
            config: .init(
                endpoint: endpoint,
                requestTimeout: 0.5,
                maxBatchSize: 1,   // flush immediately
                maxBatchInterval: 0.0,
                maxRetries: 0
            ),
            metrics: metrics
        )
        let span = OTelSpan(
            traceId: OTelSpan.newTraceID(),
            spanId: OTelSpan.newSpanID(),
            name: "test",
            startTime: Date(),
            endTime: Date()
        )
        await exporter.export(spans: [span])
        // Drain any pending retry attempts.
        await exporter.flush()

        let text = await metrics.prometheusText()
        // The exact count depends on retry fan-out, but at least
        // one failure must have been recorded for the first attempt.
        #expect(text.contains("spooktacular_otlp_export_failures_total") &&
                !text.contains("spooktacular_otlp_export_failures_total 0"),
                "Expected at least one recorded OTLP failure; got:\n\(text)")
    }
}
