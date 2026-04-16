import Foundation
import CryptoKit
import os
import SpookCore
import SpookApplication

/// Cross-region distributed lock backed by an AWS DynamoDB table.
///
/// `KubernetesLeaseLock` is cluster-scoped — a Kubernetes Lease
/// can't synchronize a controller running in us-east-1 with one
/// running in eu-west-1. That's fine for a single-cluster deploy
/// but Fortune-20 Mac fleets routinely span regions and need a
/// globally-consistent coordination primitive so two regions
/// don't both decide to scale the same runner pool.
///
/// DynamoDB gives us:
///
/// - **Global Tables**: multi-region strong-consistency for the
///   lock table itself, so a lock held in `us-east-1` is visible
///   in `eu-west-1` within seconds.
/// - **Conditional writes**: `ConditionExpression` lets us
///   implement optimistic compare-and-swap natively — no extra
///   RPCs, no race windows.
/// - **TTL**: writing an `expiresAt` epoch with a TTL attribute
///   means DynamoDB automatically evicts abandoned leases.
///
/// Signing uses our hand-rolled SigV4 (same one
/// `S3ObjectLockAuditStore` uses) so this adapter ships without a
/// new dependency — no AWS SDK, 0 extra transitive crates.
///
/// ## Table schema
///
/// The caller provisions a table with:
///
/// ```
/// Partition key: "name" (String)
/// TTL attribute: "expiresAt" (Number, epoch seconds)
/// ```
///
/// Lease records look like:
///
/// ```json
/// {
///   "name":       "runner-pool-prod",
///   "holder":    "controller-abc-pod-0",
///   "acquiredAt": 1712345678,
///   "expiresAt":  1712345693,
///   "version":    42
/// }
/// ```
///
/// ## Standards
/// - [AWS DynamoDB conditional writes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.ConditionExpressions.html)
/// - [DynamoDB Global Tables](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GlobalTables.html)
/// - [SigV4 signing process](https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html)
public actor DynamoDBDistributedLock: DistributedLockService {

    // MARK: - Configuration

    private let tableName: String
    private let region: String
    private let accessKeyID: String
    private let secretAccessKey: String
    private let sessionToken: String?
    private let endpoint: URL
    private let session: URLSession

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private let logger = Log.audit   // reuse the audit category

    public init(
        tableName: String,
        region: String = "us-east-1",
        endpoint: URL? = nil
    ) throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["AWS_ACCESS_KEY_ID"],
              let secret = env["AWS_SECRET_ACCESS_KEY"] else {
            throw DynamoDBLockError.missingCredentials
        }
        self.tableName = tableName
        self.region = region
        self.accessKeyID = key
        self.secretAccessKey = secret
        self.sessionToken = env["AWS_SESSION_TOKEN"]
        self.endpoint = endpoint
            ?? URL(string: "https://dynamodb.\(region).amazonaws.com")!
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: - DistributedLockService

    /// Acquires `name` for `holder` for at most `duration` seconds.
    ///
    /// Two paths:
    ///
    /// 1. **Fresh lock** — `PutItem` with
    ///    `ConditionExpression: attribute_not_exists(#n) OR expiresAt < :now`
    ///    so we only succeed when no other holder has a live lease.
    /// 2. **Contention** — the conditional fails; return `nil` so
    ///    callers back off without raising to the operator.
    public func acquire(
        name: String,
        holder: String,
        duration: TimeInterval
    ) async throws -> DistributedLease? {
        let now = Date()
        let lease = DistributedLease(
            name: name, holder: holder,
            acquiredAt: now, duration: duration, version: 1
        )
        let item = try itemRepresentation(for: lease)
        let payload: [String: Any] = [
            "TableName": tableName,
            "Item": item,
            "ConditionExpression": "attribute_not_exists(#n) OR expiresAt < :now",
            "ExpressionAttributeNames": ["#n": "name"],
            "ExpressionAttributeValues": [
                ":now": ["N": "\(Int(now.timeIntervalSince1970))"],
            ],
        ]
        do {
            _ = try await post(action: "PutItem", payload: payload)
            return lease
        } catch DynamoDBLockError.conditionalCheckFailed {
            return nil
        }
    }

    /// Extends a held lease by conditionally updating the record,
    /// guarded by the observed `version` so a second-controller
    /// takeover during our sleep doesn't get silently renewed.
    public func renew(
        _ lease: DistributedLease,
        duration: TimeInterval
    ) async throws -> DistributedLease {
        let now = Date()
        let renewed = DistributedLease(
            name: lease.name, holder: lease.holder,
            acquiredAt: now, duration: duration,
            version: lease.version + 1
        )
        let item = try itemRepresentation(for: renewed)
        let payload: [String: Any] = [
            "TableName": tableName,
            "Item": item,
            "ConditionExpression": "version = :v AND holder = :h",
            "ExpressionAttributeValues": [
                ":v": ["N": "\(lease.version)"],
                ":h": ["S": lease.holder],
            ],
        ]
        do {
            _ = try await post(action: "PutItem", payload: payload)
            return renewed
        } catch DynamoDBLockError.conditionalCheckFailed {
            throw DynamoDBLockError.leaseLost(name: lease.name)
        }
    }

    /// Deletes the record — conditional on still holding the lease.
    /// A failed compare-and-swap means someone else already took
    /// over; releasing anyway would invite a split-brain window.
    public func release(_ lease: DistributedLease) async throws {
        let payload: [String: Any] = [
            "TableName": tableName,
            "Key": ["name": ["S": lease.name]],
            "ConditionExpression": "version = :v AND holder = :h",
            "ExpressionAttributeValues": [
                ":v": ["N": "\(lease.version)"],
                ":h": ["S": lease.holder],
            ],
        ]
        do {
            _ = try await post(action: "DeleteItem", payload: payload)
        } catch DynamoDBLockError.conditionalCheckFailed {
            // Another holder has the lease — nothing to release.
            logger.notice("DynamoDB release: lease \(lease.name, privacy: .public) already held by someone else")
        }
    }

    // MARK: - Item representation

    /// Produces the DynamoDB JSON item for a lease. DynamoDB's wire
    /// format demands type-annotated values (`"S"`, `"N"`, `"BOOL"`),
    /// so we build them by hand rather than encoding
    /// `DistributedLease` directly with JSONEncoder.
    private func itemRepresentation(for lease: DistributedLease) throws -> [String: Any] {
        return [
            "name":       ["S": lease.name],
            "holder":     ["S": lease.holder],
            "acquiredAt": ["N": "\(Int(lease.acquiredAt.timeIntervalSince1970))"],
            "expiresAt":  ["N": "\(Int(lease.expiresAt.timeIntervalSince1970))"],
            "version":    ["N": "\(lease.version)"],
        ]
    }

    // MARK: - HTTP + SigV4

    /// POSTs a signed DynamoDB control-plane request and returns the
    /// decoded JSON body. Surfaces `ConditionalCheckFailedException`
    /// as a typed Swift error so callers can distinguish contention
    /// from genuine failures.
    private func post(action: String, payload: [String: Any]) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.setValue(endpoint.host, forHTTPHeaderField: "Host")

        let amzDate = Self.amzDateFormatter.string(from: Date())
        let shortDate = Self.shortDateFormatter.string(from: Date())
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        let auth = try signRequest(
            request: request, body: body,
            amzDate: amzDate, shortDate: shortDate
        )
        request.setValue(auth, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DynamoDBLockError.invalidResponse
        }
        if http.statusCode == 400 {
            if let body = String(data: data, encoding: .utf8),
               body.contains("ConditionalCheckFailedException") {
                throw DynamoDBLockError.conditionalCheckFailed
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DynamoDBLockError.httpError(statusCode: http.statusCode, body: body)
        }
        return data
    }

    /// Builds the SigV4 `Authorization` header. Trims and
    /// whitespace-collapses header values per §3.2, same as the
    /// S3 audit store does.
    private func signRequest(
        request: URLRequest,
        body: Data,
        amzDate: String,
        shortDate: String
    ) throws -> String {
        var headers: [(String, String)] = []
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            let normalized = value
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            headers.append((key.lowercased(), normalized))
        }
        headers.sort { $0.0 < $1.0 }
        let signedHeaders = headers.map(\.0).joined(separator: ";")
        let canonicalHeaders = headers.map { "\($0.0):\($0.1)\n" }.joined()

        let payloadHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let canonicalRequest = [
            "POST",
            "/",
            "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")

        let scope = "\(shortDate)/\(region)/dynamodb/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            SHA256.hash(data: Data(canonicalRequest.utf8)).map { String(format: "%02x", $0) }.joined(),
        ].joined(separator: "\n")

        let kDate = Self.hmacSHA256(key: Data("AWS4\(secretAccessKey)".utf8), data: Data(shortDate.utf8))
        let kRegion = Self.hmacSHA256(key: kDate, data: Data(region.utf8))
        let kService = Self.hmacSHA256(key: kRegion, data: Data("dynamodb".utf8))
        let kSigning = Self.hmacSHA256(key: kService, data: Data("aws4_request".utf8))
        let signature = Self.hmacSHA256(key: kSigning, data: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return "AWS4-HMAC-SHA256 Credential=\(accessKeyID)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }

    private static func hmacSHA256(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Shared formatters; DateFormatter allocation isn't free.
    private static let amzDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

// MARK: - Errors

public enum DynamoDBLockError: Error, LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidResponse
    case conditionalCheckFailed
    case leaseLost(name: String)
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "AWS credentials not found. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
        case .invalidResponse:
            "DynamoDB returned a non-HTTP response."
        case .conditionalCheckFailed:
            "Conditional write failed — another holder owns the lease."
        case .leaseLost(let name):
            "Lease for '\(name)' was lost to another holder; renewal rejected."
        case .httpError(let statusCode, let body):
            "DynamoDB HTTP \(statusCode): \(body)"
        }
    }
}
