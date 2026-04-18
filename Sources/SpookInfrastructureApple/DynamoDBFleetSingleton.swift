import Foundation
import SpookCore
import SpookApplication

/// Distributed ``FleetSingleton`` backed by an AWS DynamoDB table.
///
/// Used by the per-request nonce cache and the break-glass
/// ticket denylist in a multi-controller deployment. A mark is
/// an item with:
///
/// ```
/// { "id": <pk>, "expiresAt": <epoch seconds> }
/// ```
///
/// Writes are conditional (`attribute_not_exists(id) OR
/// expiresAt < :now`): the first writer succeeds, concurrent
/// writers hit `ConditionalCheckFailedException` which we
/// surface as ``MarkOutcome/alreadyConsumed``. Combined with
/// DynamoDB's TTL attribute, the backend auto-evicts expired
/// rows so the table stays size-bounded.
///
/// ## Table schema
///
/// ```
/// Partition key: "id"         (String)
/// TTL attribute: "expiresAt"  (Number, epoch seconds)
/// ```
///
/// Identical on-disk shape to ``DynamoDBDistributedLock`` so
/// operators can reuse the provisioned table by namespacing
/// IDs (`nonce:…`, `jti:…`) if preferred — but separate tables
/// are recommended for a clean IAM boundary between the two
/// use cases.
///
/// ## References
/// - [DynamoDB conditional updates with TTL](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/example_dynamodb_UpdateItemConditionalTTL_section.html)
/// - [DynamoDB conditional writes](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Expressions.ConditionExpressions.html)
public actor DynamoDBFleetSingleton: FleetSingleton {

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
        try DynamoDBDistributedLock.validateAccessKeyID(key)
        try DynamoDBDistributedLock.validateSecretAccessKey(secret)
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

    // MARK: - FleetSingleton

    public func mark(id: String, ttl: TimeInterval) async throws -> MarkOutcome {
        let now = Date()
        let expires = Int(now.addingTimeInterval(ttl).timeIntervalSince1970)
        let request = PutItemRequest(
            tableName: tableName,
            item: [
                "id": .string(id),
                "expiresAt": .number("\(expires)"),
            ],
            conditionExpression: "attribute_not_exists(id) OR expiresAt < :now",
            expressionAttributeValues: [
                ":now": .number("\(Int(now.timeIntervalSince1970))"),
            ]
        )
        do {
            _ = try await post(action: "PutItem", body: request)
            return .freshMark
        } catch DynamoDBLockError.conditionalCheckFailed {
            return .alreadyConsumed
        }
    }

    // MARK: - Internals

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
        if http.statusCode == 400,
           let text = String(data: data, encoding: .utf8),
           text.contains("ConditionalCheckFailedException") {
            throw DynamoDBLockError.conditionalCheckFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw DynamoDBLockError.httpError(
                statusCode: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}

/// Local in-process ``FleetSingleton`` for single-host
/// deployments. Guarded by a single actor so the
/// read-modify-write is trivially atomic within one process.
/// Explicitly unsafe across processes — the factory / preflight
/// should refuse this backend when tenancy is multi-tenant.
public actor InProcessFleetSingleton: FleetSingleton {

    private struct Entry {
        let expiresAt: Date
    }
    private var entries: [String: Entry] = [:]
    private let maxEntries: Int

    public init(maxEntries: Int = 100_000) {
        self.maxEntries = maxEntries
    }

    public func mark(id: String, ttl: TimeInterval) async throws -> MarkOutcome {
        let now = Date()
        pruneExpiredLocked(now: now)
        if let existing = entries[id], existing.expiresAt > now {
            return .alreadyConsumed
        }
        if entries.count >= maxEntries {
            evictOldestLocked()
        }
        entries[id] = Entry(expiresAt: now.addingTimeInterval(ttl))
        return .freshMark
    }

    private func pruneExpiredLocked(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func evictOldestLocked() {
        guard let oldest = entries.min(by: { $0.value.expiresAt < $1.value.expiresAt }) else {
            return
        }
        entries.removeValue(forKey: oldest.key)
    }
}
