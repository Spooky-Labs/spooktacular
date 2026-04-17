import Foundation
import CryptoKit
import SpookCore
import SpookApplication
import os

/// Forwards audit records to a customer-supplied webhook —
/// Splunk HEC, Datadog Logs, CloudWatch, or any generic SIEM
/// with an HTTPS ingest endpoint.
///
/// ## Wire format
///
/// One POST per batch. Body is a JSON object:
///
/// ```json
/// {
///   "source": "spooktacular",
///   "batch": [ { ...AuditRecord... }, ... ]
/// }
/// ```
///
/// When an HMAC key is configured, the request carries an
/// `X-Spook-Audit-Signature` header — `hex(hmac-sha256(key, body))`
/// — so the SIEM can reject forgeries at ingest.
///
/// ## Delivery guarantees
///
/// - **Batching**: records queue in memory (default 50 records
///   or 2 seconds, whichever comes first). The sink is a tee
///   downstream of the primary sink so in-memory loss doesn't
///   imply overall audit loss — the primary (JSONL / S3 /
///   Merkle) is the authoritative record.
/// - **Retry**: up to 3 attempts with exponential backoff
///   (1s / 2s / 4s). After that the batch is dropped and an
///   `os_log` fault entry emitted.
/// - **Ordering**: best-effort — concurrent batches may arrive
///   out of order at the endpoint. SIEMs universally expect to
///   sort on the record's own `timestamp` field.
public actor WebhookAuditSink: AuditSink {

    private static let log = Logger(
        subsystem: "com.spooktacular.audit", category: "webhook"
    )

    public struct Config: Sendable {
        /// The SIEM endpoint. Must be HTTPS in production.
        public let url: URL

        /// Optional HMAC-SHA256 key for signing the request
        /// body. When nil, no signature header is emitted.
        public let hmacKey: SymmetricKey?

        /// Additional headers to include on every request
        /// (e.g., Splunk `Authorization: Splunk <token>`,
        /// Datadog `DD-API-KEY: ...`).
        public let extraHeaders: [String: String]

        /// Maximum batch size before an out-of-band flush.
        public let batchSize: Int

        /// Maximum wait before an out-of-band flush.
        public let batchInterval: TimeInterval

        /// Per-attempt request timeout.
        public let requestTimeout: TimeInterval

        public init(
            url: URL,
            hmacKey: SymmetricKey? = nil,
            extraHeaders: [String: String] = [:],
            batchSize: Int = 50,
            batchInterval: TimeInterval = 2.0,
            requestTimeout: TimeInterval = 10.0
        ) {
            self.url = url
            self.hmacKey = hmacKey
            self.extraHeaders = extraHeaders
            self.batchSize = batchSize
            self.batchInterval = batchInterval
            self.requestTimeout = requestTimeout
        }
    }

    private let config: Config
    private let session: URLSession
    private var queue: [AuditRecord] = []
    private var flushTask: Task<Void, Never>?

    public init(config: Config) {
        self.config = config
        let session = URLSessionConfiguration.ephemeral
        session.timeoutIntervalForRequest = config.requestTimeout
        self.session = URLSession(configuration: session)
    }

    // MARK: - AuditSink

    public func record(_ entry: AuditRecord) async throws {
        queue.append(entry)
        if queue.count >= config.batchSize {
            await flush()
            return
        }
        // Schedule a deferred flush if none running.
        if flushTask == nil {
            let interval = config.batchInterval
            flushTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                await self?.deferredFlush()
            }
        }
    }

    // MARK: - Flush

    private func deferredFlush() async {
        flushTask = nil
        await flush()
    }

    /// Flush the queue immediately. Safe to call repeatedly.
    public func flush() async {
        guard !queue.isEmpty else { return }
        let batch = queue
        queue.removeAll()

        let body: Data
        do {
            let envelope = Envelope(source: "spooktacular", batch: batch)
            body = try Self.encoder.encode(envelope)
        } catch {
            Self.log.fault("Webhook audit sink: encode failed — dropping \(batch.count, privacy: .public) records: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Retry up to 3x with exponential backoff.
        var attempt = 0
        while attempt < 3 {
            do {
                try await post(body: body)
                return
            } catch {
                attempt += 1
                if attempt >= 3 {
                    Self.log.fault("Webhook audit sink: giving up after 3 attempts — dropping \(batch.count, privacy: .public) records. Last error: \(error.localizedDescription, privacy: .public)")
                    return
                }
                let delay = pow(2.0, Double(attempt - 1))  // 1s, 2s
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func post(body: Data) async throws {
        var req = URLRequest(url: config.url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in config.extraHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let key = config.hmacKey {
            let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
            let hex = Array(mac).map { String(format: "%02x", $0) }.joined()
            req.setValue(hex, forHTTPHeaderField: "X-Spook-Audit-Signature")
        }
        req.httpBody = body

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw WebhookAuditError.nonHTTPResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw WebhookAuditError.httpStatus(http.statusCode)
        }
    }

    // MARK: - Helpers

    private struct Envelope: Encodable {
        let source: String
        let batch: [AuditRecord]
    }

    nonisolated(unsafe) private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

// MARK: - Errors

public enum WebhookAuditError: Error, LocalizedError {
    case nonHTTPResponse
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            "Webhook response was not HTTP."
        case .httpStatus(let code):
            "Webhook returned HTTP \(code)."
        }
    }
}
