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

    public func record(_ entry: AuditRecord) async throws {
        do {
            _ = try await append(entry)
        } catch let error as AuditSinkError {
            throw error
        } catch let error as S3AuditError {
            throw AuditSinkError.recordingFailed(reason: error.localizedDescription)
        } catch {
            throw AuditSinkError.recordingFailed(reason: "S3 append failed: \(error.localizedDescription)")
        }
    }

    // MARK: - ImmutableAuditStore

    public func append(_ record: AuditRecord) async throws -> UInt64 {
        let seq = sequenceNumber
        pendingRecords.append(record)
        if pendingRecords.count >= batchSize {
            try await flushBatch()
        }
        // Sequence advances only after a successful buffer append and
        // optional flush — a throwing flush no longer skips a number.
        sequenceNumber += 1
        return seq
    }

    /// Flushes any pending records to S3 synchronously.
    ///
    /// Callers MUST invoke this during graceful shutdown — otherwise
    /// up to `batchSize - 1` records that were returned from
    /// ``append(_:)`` as "appended" will be lost on process exit.
    /// The class can't rely on `deinit` because the Swift runtime
    /// doesn't guarantee actor `deinit` runs before the process
    /// terminates, and `deinit` is sync-only so it couldn't call
    /// async `flushBatch()` anyway.
    public func shutdown() async {
        do {
            try await flushBatch()
        } catch {
            let dropped = self.pendingRecords.count
            Log.audit.error("S3ObjectLockAuditStore.shutdown flush failed — \(dropped) record(s) dropped: \(error.localizedDescription, privacy: .public)")
        }
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
        let ts = Date().ISO8601Format()
        let key = "\(prefix)\(startSeq)-\(endSeq)_\(ts).jsonl"

        let retainUntil = Calendar.current.date(
            byAdding: .day, value: retentionDays, to: Date()
        )!
        let retainStr = retainUntil.ISO8601Format()

        // Build and sign the S3 PutObject request
        let host = "\(bucket).s3.\(region).amazonaws.com"
        let url = URL(string: "https://\(host)/\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data

        // Inline SHA-256 hex — S3 requires `x-amz-content-sha256`
        // set BEFORE the signer reads the header list, so we
        // can't hide it inside the signer.
        let payloadHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let now = Date()

        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue("application/x-ndjson", forHTTPHeaderField: "Content-Type")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(SigV4Signer.amzDate(now), forHTTPHeaderField: "x-amz-date")
        request.setValue("COMPLIANCE", forHTTPHeaderField: "x-amz-object-lock-mode")
        request.setValue(retainStr, forHTTPHeaderField: "x-amz-object-lock-retain-until-date")
        if let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }

        // SigV4 signing — shared with DynamoDBDistributedLock so
        // the two AWS adapters can't drift on canonical-header or
        // signing-key derivation bugs.
        let signer = SigV4Signer(
            credentials: .init(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken),
            region: region,
            service: "s3"
        )
        request.setValue(signer.signature(for: request, body: data, date: now), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw S3AuditError.uploadFailed(code)
        }

        // Confirm the object is locked. An Object-Lock-enabled
        // bucket SHOULD apply the retention header, but a bucket
        // misconfiguration (Object Lock turned off after bucket
        // creation, or the role missing `s3:PutObjectRetention`)
        // can accept the PUT and silently drop the lock. A HEAD
        // with `x-amz-object-lock-mode` in the response confirms
        // the lock stuck.
        try await headVerifyLock(key: key, host: host)
    }

    /// Issues an S3 HEAD Object and fails if the object is not
    /// under Object Lock. This is the WORM correctness check that
    /// makes the adapter SOC 2 defensible.
    private func headVerifyLock(key: String, host: String) async throws {
        let url = URL(string: "https://\(host)/\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let now = Date()
        let emptyHash = SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined()
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(emptyHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(SigV4Signer.amzDate(now), forHTTPHeaderField: "x-amz-date")
        if let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }
        let signer = SigV4Signer(
            credentials: .init(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken),
            region: region,
            service: "s3"
        )
        request.setValue(signer.signature(for: request, body: Data(), date: now), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw S3AuditError.lockVerificationFailed(code)
        }
        guard let mode = http.value(forHTTPHeaderField: "x-amz-object-lock-mode"),
              !mode.isEmpty else {
            throw S3AuditError.notLocked
        }
    }
}

public enum S3AuditError: Error, LocalizedError, Sendable {
    case missingCredentials
    case uploadFailed(Int)
    case lockVerificationFailed(Int)
    case notLocked

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "AWS credentials not found. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
        case .uploadFailed(let code):
            "S3 PutObject failed with HTTP \(code)"
        case .lockVerificationFailed(let code):
            "S3 HEAD for lock verification failed with HTTP \(code)"
        case .notLocked:
            "S3 PutObject returned success but the object has no x-amz-object-lock-mode header — Object Lock is not enforced on this bucket."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missingCredentials:
            "Export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or attach an IAM role to the EC2 host. For local dev, consider `aws configure` + exporting the profile."
        case .uploadFailed(let code):
            switch code {
            case 403: "Check that the IAM principal has `s3:PutObject` + `s3:PutObjectRetention` on the bucket and that Object Lock is enabled."
            case 400: "Check SPOOK_AUDIT_S3_BUCKET name and SPOOK_AUDIT_S3_REGION — 400 often means the region's endpoint doesn't host that bucket."
            default: "HTTP \(code) from S3. Inspect CloudTrail for the failed PutObject call; the `Errors.S3.InvalidArgument` → bucket misconfiguration is the most common cause."
            }
        case .lockVerificationFailed:
            "HEAD after PUT failed. Grant `s3:GetObject` and `s3:GetObjectRetention` on the bucket policy."
        case .notLocked:
            "Enable Object Lock on the bucket (AWS S3 console → Properties → Object Lock → Enable). Object Lock cannot be turned on after bucket creation — create a new bucket with Object Lock enabled from the start."
        }
    }
}
