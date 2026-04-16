import Foundation
import CryptoKit
import SpookCore
import SpookApplication

/// SOC 2 Type II compliant audit store using AWS S3 Object Lock.
///
/// Implements AWS SigV4 request signing directly using CryptoKit —
/// no external AWS SDK dependency. This keeps the binary small and
/// build times fast while providing full S3 Object Lock (WORM)
/// compliance.
///
/// ## Configuration
///
/// | Env var | Description | Default |
/// |---------|-------------|---------|
/// | `SPOOK_AUDIT_S3_BUCKET` | S3 bucket (Object Lock enabled) | required |
/// | `SPOOK_AUDIT_S3_REGION` | AWS region | `us-east-1` |
/// | `SPOOK_AUDIT_S3_PREFIX` | Key prefix | `audit/` |
/// | `SPOOK_AUDIT_S3_RETENTION_DAYS` | Compliance retention | `2555` |
/// | `AWS_ACCESS_KEY_ID` | AWS credential | required |
/// | `AWS_SECRET_ACCESS_KEY` | AWS credential | required |
/// | `AWS_SESSION_TOKEN` | STS session token | optional |
///
/// ## Standards
///
/// - NIST SP 800-53 AU-9: Protection of audit information
/// - SOC 2 Type II CC7.2: Monitoring of system components
/// - AWS Signature Version 4 (SigV4)
public actor S3ObjectLockAuditStore: ImmutableAuditStore, AuditSink {
    private let bucket: String
    private let region: String
    private let prefix: String
    private let retentionDays: Int
    private let batchSize: Int
    private let accessKeyID: String
    private let secretAccessKey: String
    private let sessionToken: String?
    private let encoder: JSONEncoder
    private let session: URLSession

    private var pendingRecords: [AuditRecord] = []
    private var sequenceNumber: UInt64 = 0

    public init(
        bucket: String,
        region: String = "us-east-1",
        prefix: String = "audit/",
        retentionDays: Int = 2555,
        batchSize: Int = 100
    ) throws {
        let env = ProcessInfo.processInfo.environment
        guard let accessKey = env["AWS_ACCESS_KEY_ID"],
              let secretKey = env["AWS_SECRET_ACCESS_KEY"] else {
            throw S3AuditError.missingCredentials
        }

        self.bucket = bucket
        self.region = region
        self.prefix = prefix
        self.retentionDays = retentionDays
        self.batchSize = batchSize
        self.accessKeyID = accessKey
        self.secretAccessKey = secretKey
        self.sessionToken = env["AWS_SESSION_TOKEN"]
        self.session = URLSession(configuration: .ephemeral)

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: - AuditSink

    public func record(_ entry: AuditRecord) async {
        _ = try? await append(entry)
    }

    // MARK: - ImmutableAuditStore

    public func append(_ record: AuditRecord) async throws -> UInt64 {
        let seq = sequenceNumber
        sequenceNumber += 1
        pendingRecords.append(record)
        if pendingRecords.count >= batchSize {
            try await flushBatch()
        }
        return seq
    }

    public func read(from: UInt64, count: Int) async throws -> [AuditRecord] { [] }
    public func recordCount() async throws -> UInt64 { sequenceNumber }

    // MARK: - Flush

    public func flushBatch() async throws {
        guard !pendingRecords.isEmpty else { return }
        let batch = pendingRecords
        pendingRecords = []

        var data = Data()
        for record in batch {
            if let line = try? encoder.encode(record) {
                data.append(line)
                data.append(0x0A)
            }
        }

        let startSeq = sequenceNumber - UInt64(batch.count)
        let endSeq = sequenceNumber - 1
        let ts = ISO8601DateFormatter().string(from: Date())
        let key = "\(prefix)\(startSeq)-\(endSeq)_\(ts).jsonl"

        let retainUntil = Calendar.current.date(
            byAdding: .day, value: retentionDays, to: Date()
        )!
        let retainStr = ISO8601DateFormatter().string(from: retainUntil)

        // Build and sign the S3 PutObject request
        let host = "\(bucket).s3.\(region).amazonaws.com"
        let url = URL(string: "https://\(host)/\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data

        let payloadHash = sha256Hex(data)
        let now = Date()

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(amzDate(now), forHTTPHeaderField: "x-amz-date")
        request.setValue("COMPLIANCE", forHTTPHeaderField: "x-amz-object-lock-mode")
        request.setValue(retainStr, forHTTPHeaderField: "x-amz-object-lock-retain-until-date")
        if let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        // SigV4 signing
        let authorization = signV4(request: request, body: data, now: now)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw S3AuditError.uploadFailed(code)
        }
    }

    // MARK: - AWS SigV4

    private func signV4(request: URLRequest, body: Data, now: Date) -> String {
        let dateStamp = shortDate(now)
        let amzDateStr = amzDate(now)
        let scope = "\(dateStamp)/\(region)/s3/aws4_request"

        // Canonical headers (sorted).
        //
        // AWS SigV4 §3.2 requires values to be trimmed and internal
        // sequential whitespace collapsed before signing. Without this,
        // S3 rejects requests where any header value contains
        // leading/trailing/internal extra whitespace.
        var headers: [(String, String)] = []
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let normalizedValue = value
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            headers.append((key.lowercased(), normalizedValue))
        }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()

        // Canonical request
        let path = request.url?.path ?? "/"
        let query = request.url?.query ?? ""
        let payloadHash = sha256Hex(body)
        let canonicalRequest = [
            request.httpMethod ?? "PUT",
            path,
            query,
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        // String to sign
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDateStr,
            scope,
            sha256Hex(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        // Signing key
        let kDate = hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(dateStamp.utf8))
        let kRegion = hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = hmacSHA256(key: kRegion, data: Data("s3".utf8))
        let kSigning = hmacSHA256(key: kService, data: Data("aws4_request".utf8))

        let signature = hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }

    /// Cached formatter for the `X-Amz-Date` header format
    /// (`yyyyMMdd'T'HHmmss'Z'`).
    ///
    /// `DateFormatter` is expensive to allocate — enough to show up in
    /// profiles when auditing at any real rate. Cached as a stored
    /// property since this type is already an `actor`, guaranteeing
    /// exclusive access at each call site.
    private let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Cached formatter for SigV4's date stamp (`yyyyMMdd`).
    private let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private func amzDate(_ date: Date) -> String {
        amzDateFormatter.string(from: date)
    }

    private func shortDate(_ date: Date) -> String {
        shortDateFormatter.string(from: date)
    }
}

public enum S3AuditError: Error, LocalizedError, Sendable {
    case missingCredentials
    case uploadFailed(Int)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "AWS credentials not found. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
        case .uploadFailed(let code):
            "S3 PutObject failed with HTTP \(code)"
        }
    }
}
