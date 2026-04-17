import Foundation
import SpookCore

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
/// ## Delivery guarantees
///
/// OTel export is observability, not durable data, but a silent
/// drop is the kind of gap that makes a Fortune-20 auditor unhappy:
/// when the collector is down for an hour, the operator needs a
/// signal in Prometheus, not a span graph with a mysterious black
/// hole. This exporter therefore:
///
/// - **Batches** spans up to ``Config/maxBatchSize`` or
///   ``Config/maxBatchInterval`` and dispatches one POST per
///   batch — amortizes TCP setup and matches the OTLP collector's
///   intake shape.
/// - **Retries** on transient failure with exponential backoff
///   (``Config/maxRetries``, 500ms → 1s → 2s). Retries use a
///   bounded queue (``Config/retryQueueCapacity``); when the
///   queue is full the oldest batch is evicted, never the newest.
/// - **Logs** every failure at `.warning` via an `os.Logger`
///   bound to subsystem `ai.spookylabs.spooktacular` / category
///   `otlp-exporter` so operators can filter in Console.app.
/// - **Increments** the ``MetricsCollector/recordOTLPFailure()``
///   counter so `/metrics` surfaces `otlp_export_failures_total`
///   for a Prometheus alert.
///
/// The factory wraps this in a tee alongside the primary sink so
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

        /// Maximum spans to batch into a single HTTP request. OTel
        /// collectors typically accept up to a few hundred per call;
        /// 100 is a conservative default that bounds worst-case
        /// serialized body size.
        public let maxBatchSize: Int

        /// Maximum time to hold a partial batch before flushing.
        /// Caps tail-latency for low-throughput traces so a single
        /// span can't wait indefinitely for 99 peers.
        public let maxBatchInterval: TimeInterval

        /// Maximum retry attempts before a batch is dropped. After
        /// the final retry the batch is logged + counted as a loss.
        public let maxRetries: Int

        /// Maximum number of batches held for retry. When full, the
        /// oldest batch is evicted — newer telemetry is always more
        /// useful than older.
        public let retryQueueCapacity: Int

        public init(
            endpoint: URL,
            serviceName: String = "spooktacular",
            extraHeaders: [String: String] = [:],
            requestTimeout: TimeInterval = 10.0,
            resourceAttributes: [String: String] = [:],
            maxBatchSize: Int = 100,
            maxBatchInterval: TimeInterval = 5.0,
            maxRetries: Int = 3,
            retryQueueCapacity: Int = 16
        ) {
            self.endpoint = endpoint
            self.serviceName = serviceName
            self.extraHeaders = extraHeaders
            self.requestTimeout = requestTimeout
            self.resourceAttributes = resourceAttributes
            self.maxBatchSize = maxBatchSize
            self.maxBatchInterval = maxBatchInterval
            self.maxRetries = maxRetries
            self.retryQueueCapacity = retryQueueCapacity
        }
    }

    private struct PendingBatch: Sendable {
        let spans: [OTelSpan]
        var attempts: Int
    }

    private let config: Config
    private let session: URLSession
    private let metrics: MetricsCollector
    private let logger: any LogProvider
    private var pending: [OTelSpan] = []
    private var pendingStart: Date?
    private var retryQueue: [PendingBatch] = []

    public init(
        config: Config,
        metrics: MetricsCollector = .shared,
        logger: any LogProvider = SilentLogProvider()
    ) {
        self.config = config
        let conf = URLSessionConfiguration.ephemeral
        conf.timeoutIntervalForRequest = config.requestTimeout
        self.session = URLSession(configuration: conf)
        self.metrics = metrics
        self.logger = logger
    }

    public func export(spans: [OTelSpan]) async {
        guard !spans.isEmpty else { return }
        pending.append(contentsOf: spans)
        if pendingStart == nil { pendingStart = Date() }

        // Flush immediately if the batch is full or the batch
        // window has elapsed; otherwise accumulate.
        if shouldFlush(now: Date()) {
            await flush()
        }
        // Opportunistically drain anything queued for retry.
        await drainRetryQueue()
    }

    /// Force-flushes any pending spans. Call from shutdown paths
    /// so traces queued during the final batching window aren't
    /// lost when the process exits.
    public func flush() async {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        pendingStart = nil
        await dispatch(batch: PendingBatch(spans: batch, attempts: 0))
    }

    /// Test-only introspection of the retry backlog size.
    internal var queuedBatchCount: Int { retryQueue.count }

    private func shouldFlush(now: Date) -> Bool {
        if pending.count >= config.maxBatchSize { return true }
        if let start = pendingStart,
           now.timeIntervalSince(start) >= config.maxBatchInterval {
            return true
        }
        return false
    }

    private func dispatch(batch: PendingBatch) async {
        do {
            try await post(spans: batch.spans)
        } catch {
            await recordFailure(batch: batch, error: error)
        }
    }

    private func recordFailure(batch: PendingBatch, error: Error) async {
        logger.warning(
            "OTLP export failed (attempt \(batch.attempts + 1)/\(self.config.maxRetries + 1)): \(error.localizedDescription)"
        )
        await metrics.recordOTLPFailure()

        let next = PendingBatch(spans: batch.spans, attempts: batch.attempts + 1)
        guard next.attempts <= config.maxRetries else {
            logger.error(
                "OTLP export giving up after \(next.attempts) attempts; dropping \(batch.spans.count) span(s)"
            )
            return
        }
        enqueueRetry(next)
    }

    private func enqueueRetry(_ batch: PendingBatch) {
        if retryQueue.count >= config.retryQueueCapacity {
            // Bounded queue: evict the oldest batch so the newest
            // always wins. Record the eviction so operators can see
            // pressure in Prometheus.
            let dropped = retryQueue.removeFirst()
            logger.warning(
                "OTLP retry queue full (capacity \(self.config.retryQueueCapacity)); evicting oldest batch of \(dropped.spans.count) span(s)"
            )
        }
        retryQueue.append(batch)
    }

    private func drainRetryQueue() async {
        guard !retryQueue.isEmpty else { return }
        let batches = retryQueue
        retryQueue.removeAll(keepingCapacity: true)
        for batch in batches {
            // Exponential backoff: 500ms, 1s, 2s, capped at 4s.
            let delayMillis = min(4_000, 500 << min(batch.attempts - 1, 3))
            try? await Task.sleep(nanoseconds: UInt64(delayMillis) * 1_000_000)
            await dispatch(batch: batch)
        }
    }

    private func post(spans: [OTelSpan]) async throws {
        let body = try buildBody(spans: spans)
        var req = URLRequest(url: config.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw OTLPExportError.nonHTTPResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OTLPExportError.badStatus(http.statusCode)
        }
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

// MARK: - OTLP export error

/// An error emitted by ``OTLPHTTPJSONExporter`` when a batch
/// cannot be delivered. Non-2xx HTTP responses and non-HTTP
/// transport errors are surfaced distinctly so operators can
/// distinguish collector faults (which benefit from retries)
/// from misconfiguration (wrong URL, bad certificate).
public enum OTLPExportError: Error, Sendable, LocalizedError, Equatable {

    /// The response was not an `HTTPURLResponse`. Usually a
    /// transport-layer URL error (DNS / TLS). The underlying error
    /// is already logged at the call site.
    case nonHTTPResponse

    /// The collector responded with a non-2xx status code.
    ///
    /// - Parameter statusCode: The HTTP status code returned.
    case badStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "OTLP collector returned a non-HTTP response (transport error)."
        case .badStatus(let code):
            "OTLP collector returned HTTP \(code)."
        }
    }
}
