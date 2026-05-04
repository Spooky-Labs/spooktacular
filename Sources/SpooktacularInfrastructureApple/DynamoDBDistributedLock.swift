import Foundation
import CryptoKit
import os
import SpooktacularCore
import SpooktacularApplication

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
        try Self.validateAccessKeyID(key)
        try Self.validateSecretAccessKey(secret)
        // Construct the DynamoDB endpoint. Prefer the caller-
        // supplied `endpoint` (LocalStack, custom VPC endpoint);
        // otherwise derive from the region. The URL construction
        // is guarded rather than force-unwrapped — a syntactically
        // invalid region would otherwise crash the process at
        // init.
        let resolvedEndpoint: URL
        if let endpoint {
            resolvedEndpoint = endpoint
        } else {
            guard let derived = URL(string: "https://dynamodb.\(region).amazonaws.com") else {
                throw DynamoDBLockError.invalidEndpoint(region: region)
            }
            resolvedEndpoint = derived
        }
        self.tableName = tableName
        self.region = region
        self.accessKeyID = key
        self.secretAccessKey = secret
        self.sessionToken = env["AWS_SESSION_TOKEN"]
        self.endpoint = resolvedEndpoint
        self.session = URLSession(configuration: .ephemeral)
    }

    /// Validates the shape of `AWS_ACCESS_KEY_ID`.
    ///
    /// AWS access key IDs follow the pattern
    /// `^(AKIA|ASIA)[A-Z0-9]{16}$` — `AKIA` prefixes a long-term
    /// IAM user key, `ASIA` a short-term STS session token. A
    /// string outside that shape is a typo or an unrelated
    /// value that will fail at SigV4 time anyway; failing at
    /// init gives the operator a clear error at a predictable
    /// location.
    static func validateAccessKeyID(_ value: String) throws {
        // Length + charset guard before regex-like inspection so
        // the message can be precise.
        guard value.count == 20 else {
            throw DynamoDBLockError.invalidAccessKeyID
        }
        let prefix = String(value.prefix(4))
        guard prefix == "AKIA" || prefix == "ASIA" else {
            throw DynamoDBLockError.invalidAccessKeyID
        }
        for scalar in value.unicodeScalars {
            let c = scalar.value
            let isUpper = (0x41...0x5A).contains(c)
            let isDigit = (0x30...0x39).contains(c)
            guard isUpper || isDigit else {
                throw DynamoDBLockError.invalidAccessKeyID
            }
        }
    }

    /// Validates the shape of `AWS_SECRET_ACCESS_KEY`.
    ///
    /// Standard IAM secret keys are 40 base64-ish ASCII bytes;
    /// STS session keys and FIPS / GovCloud variants shift the
    /// length slightly. We accept any printable-ASCII string in
    /// [16, 128] — the real validator is the AWS service, this
    /// guard exists to catch fat-fingered `=========` values
    /// that would otherwise sign malformed requests forever.
    static func validateSecretAccessKey(_ value: String) throws {
        let length = value.count
        guard length >= 16 && length <= 128 else {
            throw DynamoDBLockError.invalidSecretAccessKey
        }
        for scalar in value.unicodeScalars {
            let c = scalar.value
            // Printable ASCII excluding control and DEL.
            guard (0x20...0x7E).contains(c) else {
                throw DynamoDBLockError.invalidSecretAccessKey
            }
        }
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
        let request = PutItemRequest(
            tableName: tableName,
            item: leaseItem(lease),
            conditionExpression: "attribute_not_exists(#n) OR expiresAt < :now",
            expressionAttributeNames: ["#n": "name"],
            expressionAttributeValues: [":now": .number("\(Int(now.timeIntervalSince1970))")]
        )
        do {
            _ = try await post(action: "PutItem", body: request)
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
        let nextCount = lease.renewalCount + 1
        guard nextCount <= DistributedLease.maxRenewals else {
            throw DistributedLockServiceError.renewalBudgetExhausted(
                name: lease.name, count: nextCount
            )
        }
        let now = Date()
        let renewed = DistributedLease(
            name: lease.name, holder: lease.holder,
            acquiredAt: now, duration: duration,
            version: lease.version + 1,
            renewalCount: nextCount
        )
        let ok = try await compareAndSwap(old: lease, new: renewed)
        guard ok else {
            throw DynamoDBLockError.leaseLost(name: lease.name)
        }
        return renewed
    }

    /// Advances a lease from `old` to `new` via a conditional
    /// DynamoDB `PutItem`. Returns `true` on success, `false`
    /// when a concurrent writer won the race.
    ///
    /// The CAS condition pins both `version` and `holder` —
    /// matching version alone would let a hijacker with the
    /// same version number (after a full takeover round)
    /// overwrite our update.
    public func compareAndSwap(
        old: DistributedLease,
        new: DistributedLease
    ) async throws -> Bool {
        guard new.renewalCount <= DistributedLease.maxRenewals else {
            throw DistributedLockServiceError.renewalBudgetExhausted(
                name: new.name, count: new.renewalCount
            )
        }
        let request = PutItemRequest(
            tableName: tableName,
            item: leaseItem(new),
            conditionExpression: "version = :v AND holder = :h",
            expressionAttributeValues: [
                ":v": .number("\(old.version)"),
                ":h": .string(old.holder),
            ]
        )
        do {
            _ = try await post(action: "PutItem", body: request)
            return true
        } catch DynamoDBLockError.conditionalCheckFailed {
            return false
        }
    }

    /// Deletes the record — conditional on still holding the lease.
    /// A failed compare-and-swap means someone else already took
    /// over; releasing anyway would invite a split-brain window.
    public func release(_ lease: DistributedLease) async throws {
        let request = DeleteItemRequest(
            tableName: tableName,
            key: ["name": .string(lease.name)],
            conditionExpression: "version = :v AND holder = :h",
            expressionAttributeValues: [
                ":v": .number("\(lease.version)"),
                ":h": .string(lease.holder),
            ]
        )
        do {
            _ = try await post(action: "DeleteItem", body: request)
        } catch DynamoDBLockError.conditionalCheckFailed {
            // Another holder has the lease — nothing to release.
            logger.notice("DynamoDB release: lease \(lease.name, privacy: .public) already held by someone else")
        }
    }

    // MARK: - Item representation

    /// Builds the typed DynamoDB item for a lease.
    ///
    /// `DDBAttribute` encodes to the type-annotated wire form
    /// (`{"S":"foo"}` / `{"N":"42"}`) the DynamoDB API demands,
    /// so the rest of the code path can stay in Swift-native
    /// types. This replaces the prior `[String: [String: String]]`
    /// free-form dictionaries which had no compile-time guarantee
    /// that a required attribute like `expiresAt` was present.
    private func leaseItem(_ lease: DistributedLease) -> [String: DDBAttribute] {
        [
            "name": .string(lease.name),
            "holder": .string(lease.holder),
            "acquiredAt": .number("\(Int(lease.acquiredAt.timeIntervalSince1970))"),
            "expiresAt": .number("\(Int(lease.expiresAt.timeIntervalSince1970))"),
            "version": .number("\(lease.version)"),
            "renewalCount": .number("\(lease.renewalCount)"),
        ]
    }

    // MARK: - HTTP + SigV4

    /// POSTs a signed DynamoDB control-plane request and returns the
    /// decoded JSON body. Surfaces `ConditionalCheckFailedException`
    /// as a typed Swift error so callers can distinguish contention
    /// from genuine failures.
    private func post<Body: Encodable>(action: String, body: Body) async throws -> Data {
        let body = try encoder.encode(body)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue("DynamoDB_20120810.\(action)", forHTTPHeaderField: "X-Amz-Target")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.setValue(endpoint.host, forHTTPHeaderField: "Host")

        let now = Date()
        request.setValue(SigV4Signer.amzDate(now), forHTTPHeaderField: "X-Amz-Date")
        if let token = sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }

        // Shared signer with S3ObjectLockAuditStore; the two AWS
        // adapters stay in lockstep on canonical-request rules
        // because they go through the same code path.
        let signer = SigV4Signer(
            credentials: .init(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, sessionToken: sessionToken),
            region: region,
            service: "dynamodb"
        )
        request.setValue(signer.signature(for: request, body: body, date: now), forHTTPHeaderField: "Authorization")

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
}

// MARK: - DynamoDB wire-format helpers

/// A single DynamoDB attribute value.
///
/// DynamoDB's wire protocol requires type-annotated values:
/// `{"S":"foo"}` for strings, `{"N":"42"}` for numbers (note that
/// numbers are transmitted as strings). Representing this as an
/// enum gives compile-time coverage of the two cases we use and
/// makes the encode path symmetric — no more stringly-typed
/// `[String: [String: String]]` with an invariant the compiler
/// can't check.
enum DDBAttribute: Codable, Sendable, Equatable {
    case string(String)
    case number(String)

    private enum CodingKeys: String, CodingKey {
        case s = "S"
        case n = "N"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(String.self, forKey: .s) {
            self = .string(s); return
        }
        if let n = try c.decodeIfPresent(String.self, forKey: .n) {
            self = .number(n); return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .s, in: c,
            debugDescription: "DynamoDB attribute must carry an S or N key"
        )
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let s): try c.encode(s, forKey: .s)
        case .number(let n): try c.encode(n, forKey: .n)
        }
    }
}

/// Typed `PutItem` request body. The custom `CodingKeys` match
/// DynamoDB's PascalCase wire names without the need for a custom
/// `JSONEncoder.keyEncodingStrategy` (which would also affect
/// nested `DDBAttribute` keys we want in upper-case).
struct PutItemRequest: Encodable, Sendable {
    let tableName: String
    let item: [String: DDBAttribute]
    let conditionExpression: String?
    let expressionAttributeNames: [String: String]?
    let expressionAttributeValues: [String: DDBAttribute]?

    init(
        tableName: String,
        item: [String: DDBAttribute],
        conditionExpression: String? = nil,
        expressionAttributeNames: [String: String]? = nil,
        expressionAttributeValues: [String: DDBAttribute]? = nil
    ) {
        self.tableName = tableName
        self.item = item
        self.conditionExpression = conditionExpression
        self.expressionAttributeNames = expressionAttributeNames
        self.expressionAttributeValues = expressionAttributeValues
    }

    enum CodingKeys: String, CodingKey {
        case tableName = "TableName"
        case item = "Item"
        case conditionExpression = "ConditionExpression"
        case expressionAttributeNames = "ExpressionAttributeNames"
        case expressionAttributeValues = "ExpressionAttributeValues"
    }
}

/// Typed `DeleteItem` request body. Mirrors `PutItemRequest` in
/// structure but uses the DynamoDB `Key` field (the lease's
/// identifying attributes) rather than the full item.
struct DeleteItemRequest: Encodable, Sendable {
    let tableName: String
    let key: [String: DDBAttribute]
    let conditionExpression: String?
    let expressionAttributeValues: [String: DDBAttribute]?

    enum CodingKeys: String, CodingKey {
        case tableName = "TableName"
        case key = "Key"
        case conditionExpression = "ConditionExpression"
        case expressionAttributeValues = "ExpressionAttributeValues"
    }
}

// MARK: - Errors

public enum DynamoDBLockError: Error, LocalizedError, Sendable, Equatable {
    case missingCredentials
    case invalidAccessKeyID
    case invalidSecretAccessKey
    case invalidEndpoint(region: String)
    case invalidResponse
    case conditionalCheckFailed
    case leaseLost(name: String)
    case httpError(statusCode: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials:
            "AWS credentials not found. Set AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY."
        case .invalidAccessKeyID:
            "AWS_ACCESS_KEY_ID doesn't match the AWS key ID shape (^(AKIA|ASIA)[A-Z0-9]{16}$)."
        case .invalidSecretAccessKey:
            "AWS_SECRET_ACCESS_KEY is not a printable-ASCII string of length 16…128."
        case .invalidEndpoint(let region):
            "Could not derive a DynamoDB endpoint URL for region '\(region)'."
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

    public var recoverySuggestion: String? {
        switch self {
        case .missingCredentials:
            "Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, or run on an EC2 instance with an attached IAM role (the credential provider will pick it up)."
        case .invalidAccessKeyID:
            "AWS access keys always match ^(AKIA|ASIA)[A-Z0-9]{16}$. Check for stray whitespace or a partial copy-paste."
        case .invalidSecretAccessKey:
            "Standard IAM secret keys are 40 base64-ish ASCII bytes. Re-export from the IAM console and make sure your shell didn't strip padding."
        case .invalidEndpoint(let region):
            "Check SPOOKTACULAR_DYNAMO_REGION '\(region)' — it must be a valid AWS region code (e.g. us-east-1, eu-west-1)."
        case .invalidResponse:
            "The DynamoDB endpoint returned a non-HTTP response. Verify SPOOKTACULAR_DYNAMO_ENDPOINT (if set), DNS, and network reachability."
        case .conditionalCheckFailed:
            "Expected — another holder owns the lease. Retry after a short backoff; this is not an error."
        case .leaseLost:
            "Another holder took the lease during a renew. Shorten the renew interval or investigate why your process paused past the TTL."
        case .httpError(let code, _):
            code == 400 ? "Check SPOOKTACULAR_DYNAMO_TABLE schema and IAM permissions — 400 typically means a malformed request or missing dynamodb:PutItem."
                : "HTTP \(code) from DynamoDB. Consult the response body + AWS CloudTrail for details."
        }
    }
}
