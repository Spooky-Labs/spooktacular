import Testing
import Foundation
@testable import SpookApplication

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
}
