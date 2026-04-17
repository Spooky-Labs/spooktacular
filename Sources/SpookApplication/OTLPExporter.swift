import Foundation

/// A minimal OpenTelemetry span record — just enough to serialize
/// into an OTLP-HTTP-JSON `resourceSpans` payload.
///
/// Design is deliberately not a full OTel SDK port: we have one
/// service (Spooktacular) emitting traces for HTTP requests and
/// VM-lifecycle events, not a general-purpose library. The
/// trade-off is fewer features (no sampling, no instrumentation
/// libraries, no span links, no resource auto-detection) and a
/// handful of files vs. hundreds.
///
/// The SDK-compatibility surface that matters:
///
/// - Trace / span IDs are random bytes in the OTel-standard
///   widths (16 bytes / 8 bytes respectively; base16 on the
///   wire).
/// - Timestamps are Unix nanoseconds, stringified because
///   OTLP-JSON can't safely represent 64-bit integers as
///   numbers.
/// - Attribute values wrap in the `stringValue` / `intValue` /
///   `boolValue` tag discriminator OTLP-JSON requires.
///
/// Consumers include Grafana Tempo, Honeycomb, Datadog APM,
/// Dynatrace, AWS X-Ray (via ADOT Collector), and anything else
/// that accepts OTLP-HTTP.
public struct OTelSpan: Sendable {

    public let traceId: String     // 32 hex chars
    public let spanId: String      // 16 hex chars
    public let parentSpanId: String?   // 16 hex chars, nil → root span
    public let name: String
    public let kind: Kind
    public let startTime: Date
    public let endTime: Date
    public let attributes: [String: AttributeValue]
    public let status: Status

    public enum Kind: Int, Sendable {
        case unspecified = 0
        case `internal` = 1
        case server = 2
        case client = 3
        case producer = 4
        case consumer = 5
    }

    public enum Status: Sendable {
        case unset
        case ok
        case error(message: String)
    }

    public enum AttributeValue: Sendable {
        case string(String)
        case int(Int64)
        case bool(Bool)
        case double(Double)
    }

    public init(
        traceId: String,
        spanId: String,
        parentSpanId: String? = nil,
        name: String,
        kind: Kind = .server,
        startTime: Date,
        endTime: Date,
        attributes: [String: AttributeValue] = [:],
        status: Status = .unset
    ) {
        self.traceId = traceId
        self.spanId = spanId
        self.parentSpanId = parentSpanId
        self.name = name
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.attributes = attributes
        self.status = status
    }

    /// Allocates a cryptographically-random 16-byte trace ID,
    /// formatted as 32 lowercase hex chars per OTLP-JSON spec.
    public static func newTraceID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<bytes.count { bytes[i] = .random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Allocates a cryptographically-random 8-byte span ID.
    public static func newSpanID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<bytes.count { bytes[i] = .random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Anything that consumes spans. Implementations include the
/// OTLP-HTTP exporter below; tests use an in-memory recording
/// exporter.
public protocol OTelExporter: Sendable {
    func export(spans: [OTelSpan]) async
}

// MARK: - OTLP-HTTP-JSON exporter

/// Exports spans to an OpenTelemetry Protocol (OTLP) receiver
/// over HTTP with a JSON-serialized body. Matches the format
/// specified in [OTLP /HTTP-JSON spec][1].
///
/// Designed for at-most-once delivery with drop-on-failure —
/// tracing is observability, not authoritative data. The
/// factory wraps this in a tee alongside the primary sink so
/// a stalled collector never backs up VM operations.
///
/// [1]: https://opentelemetry.io/docs/specs/otlp/#otlphttp
public actor OTLPHTTPJSONExporter: OTelExporter {

    public struct Config: Sendable {
        public let endpoint: URL           // e.g. https://collector.example.com/v1/traces
        public let serviceName: String     // "spooktacular"
        public let extraHeaders: [String: String]
        public let requestTimeout: TimeInterval
        public let resourceAttributes: [String: String]

        public init(
            endpoint: URL,
            serviceName: String = "spooktacular",
            extraHeaders: [String: String] = [:],
            requestTimeout: TimeInterval = 10.0,
            resourceAttributes: [String: String] = [:]
        ) {
            self.endpoint = endpoint
            self.serviceName = serviceName
            self.extraHeaders = extraHeaders
            self.requestTimeout = requestTimeout
            self.resourceAttributes = resourceAttributes
        }
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config) {
        self.config = config
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = config.requestTimeout
        self.session = URLSession(configuration: conf)
    }

    public func export(spans: [OTelSpan]) async {
        guard !spans.isEmpty else { return }
        let body: Data
        do {
            body = try buildBody(spans: spans)
        } catch {
            return
        }
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body
        // Best-effort: drop on any error. Traces are observability,
        // not durable.
        _ = try? await session.data(for: req)
    }

    // MARK: - OTLP JSON shape

    private func buildBody(spans: [OTelSpan]) throws -> Data {
        var resourceAttrs: [[String: Any]] = [
            ["key": "service.name", "value": ["stringValue": config.serviceName]]
        ]
        for (k, v) in config.resourceAttributes {
            resourceAttrs.append(["key": k, "value": ["stringValue": v]])
        }

        let spansJSON: [[String: Any]] = spans.map { span in
            let start = UInt64(span.startTime.timeIntervalSince1970 * 1_000_000_000)
            let end = UInt64(span.endTime.timeIntervalSince1970 * 1_000_000_000)

            var attrs: [[String: Any]] = []
            for (k, v) in span.attributes.sorted(by: { $0.key < $1.key }) {
                attrs.append(["key": k, "value": Self.otlpValue(v)])
            }

            var status: [String: Any] = [:]
            switch span.status {
            case .unset:
                status = ["code": 0]
            case .ok:
                status = ["code": 1]
            case .error(let msg):
                status = ["code": 2, "message": msg]
            }

            var spanJSON: [String: Any] = [
                "traceId": span.traceId,
                "spanId": span.spanId,
                "name": span.name,
                "kind": span.kind.rawValue,
                "startTimeUnixNano": String(start),
                "endTimeUnixNano": String(end),
                "attributes": attrs,
                "status": status
            ]
            if let parent = span.parentSpanId, !parent.isEmpty {
                spanJSON["parentSpanId"] = parent
            }
            return spanJSON
        }

        let payload: [String: Any] = [
            "resourceSpans": [[
                "resource": ["attributes": resourceAttrs],
                "scopeSpans": [[
                    "scope": ["name": "com.spooktacular"],
                    "spans": spansJSON
                ]]
            ]]
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    public static func otlpValue(_ v: OTelSpan.AttributeValue) -> [String: Any] {
        switch v {
        case .string(let s): return ["stringValue": s]
        case .int(let i):    return ["intValue": String(i)]
        case .bool(let b):   return ["boolValue": b]
        case .double(let d): return ["doubleValue": d]
        }
    }
}
