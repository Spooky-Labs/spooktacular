import Foundation
import SpookCore
import SpookApplication

/// Distributed lock backed by Kubernetes Lease objects.
///
/// Uses optimistic concurrency (resourceVersion) to prevent
/// split-brain. If the lease holder crashes, the lease expires
/// and another host can acquire it.
public actor KubernetesLeaseLock: DistributedLockService {
    private let apiURL: URL
    private let namespace: String
    private let session: URLSession
    private let token: String?

    private static let decoder = JSONDecoder()
    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    public init(apiURL: URL, namespace: String, session: URLSession = .shared, token: String? = nil) {
        self.apiURL = apiURL
        self.namespace = namespace
        self.session = session
        self.token = token
    }

    public func acquire(name: String, holder: String, duration: TimeInterval) async throws -> DistributedLease? {
        // GET the lease. If it doesn't exist or is expired, create/update it.
        let url = leaseURL(name: name)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 404 {
            return try await createLease(name: name, holder: holder, duration: duration)
        }
        guard status == 200 else { return nil }

        // A typed Lease replaces the prior [String: Any] + as?
        // cascade: a schema drift at the API server surfaces as a
        // decoding error at a predictable line instead of silently
        // returning nil and failing acquire().
        let existing = try Self.decoder.decode(Lease.self, from: data)
        let currentHolder = existing.spec.holderIdentity

        if let renewTime = existing.spec.renewTime,
           let leaseDuration = existing.spec.leaseDurationSeconds,
           let renewed = try? Date(renewTime, strategy: .iso8601) {
            let expires = renewed.addingTimeInterval(TimeInterval(leaseDuration))
            if Date() < expires && currentHolder != holder {
                return nil // Held by someone else, not expired
            }
        }

        return try await updateLease(
            name: name, holder: holder, duration: duration,
            resourceVersion: existing.metadata.resourceVersion
        )
    }

    public func renew(_ lease: DistributedLease, duration: TimeInterval) async throws -> DistributedLease {
        let nextCount = lease.renewalCount + 1
        guard nextCount <= DistributedLease.maxRenewals else {
            throw DistributedLockServiceError.renewalBudgetExhausted(
                name: lease.name, count: nextCount
            )
        }
        guard let updated = try await acquire(
            name: lease.name, holder: lease.holder, duration: duration
        ) else {
            throw LockError.leaseLost(lease.name)
        }
        // Preserve the renewal count across the acquire path —
        // `acquire` returns a fresh lease, but the renew API
        // must carry the monotonic renewal budget.
        return DistributedLease(
            name: updated.name, holder: updated.holder,
            duration: duration,
            version: updated.version,
            renewalCount: nextCount
        )
    }

    public func release(_ lease: DistributedLease) async throws {
        var request = URLRequest(url: leaseURL(name: lease.name))
        request.httpMethod = "DELETE"
        addAuth(&request)
        _ = try await session.data(for: request)
    }

    /// Kubernetes CAS via `resourceVersion`. The API server
    /// rejects a PUT whose `resourceVersion` doesn't match the
    /// stored value — we translate that rejection to `false`
    /// and let the caller decide whether to retry.
    public func compareAndSwap(
        old: DistributedLease,
        new: DistributedLease
    ) async throws -> Bool {
        guard new.renewalCount <= DistributedLease.maxRenewals else {
            throw DistributedLockServiceError.renewalBudgetExhausted(
                name: new.name, count: new.renewalCount
            )
        }
        let body = Lease(
            metadata: .init(
                name: new.name, namespace: namespace,
                resourceVersion: "\(old.version)"
            ),
            spec: .init(
                holderIdentity: new.holder,
                leaseDurationSeconds: Int(new.expiresAt.timeIntervalSince(new.acquiredAt)),
                renewTime: new.acquiredAt.ISO8601Format()
            )
        )
        var request = URLRequest(url: leaseURL(name: new.name))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        addAuth(&request)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: return true
        case 409: return false // resourceVersion conflict — CAS lost the race
        default: throw LockError.acquireFailed(new.name)
        }
    }

    private func createLease(
        name: String, holder: String, duration: TimeInterval
    ) async throws -> DistributedLease {
        let url = apiURL.appendingPathComponent(
            "apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases")
        let body = Lease(
            metadata: .init(name: name, namespace: namespace, resourceVersion: nil),
            spec: .init(
                holderIdentity: holder,
                leaseDurationSeconds: Int(duration),
                renewTime: Date().ISO8601Format()
            )
        )
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        addAuth(&request)

        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 201 else {
            throw LockError.acquireFailed(name)
        }
        return DistributedLease(name: name, holder: holder, duration: duration)
    }

    private func updateLease(
        name: String, holder: String, duration: TimeInterval, resourceVersion: String?
    ) async throws -> DistributedLease {
        let body = Lease(
            metadata: .init(name: name, namespace: namespace, resourceVersion: resourceVersion),
            spec: .init(
                holderIdentity: holder,
                leaseDurationSeconds: Int(duration),
                renewTime: Date().ISO8601Format()
            )
        )
        var request = URLRequest(url: leaseURL(name: name))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoder.encode(body)
        addAuth(&request)

        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LockError.acquireFailed(name)
        }
        return DistributedLease(name: name, holder: holder, duration: duration)
    }

    private func leaseURL(name: String) -> URL {
        apiURL.appendingPathComponent(
            "apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases/\(name)"
        )
    }

    private func addAuth(_ request: inout URLRequest) {
        if let t = token { request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
    }
}

// MARK: - Lease schema

/// A Kubernetes `coordination.k8s.io/v1` Lease resource.
///
/// Typed structs replace the `[String: Any]` cascade the original
/// implementation used. Three wins over the untyped shape:
///
/// 1. The server's schema change surfaces as a decode error at a
///    predictable line instead of a silent `nil` return.
/// 2. `Sendable` comes for free — no more `@unchecked Sendable`
///    dictionaries crossing actor boundaries.
/// 3. Canonical JSON key ordering is deterministic (JSONEncoder
///    with `.sortedKeys`), which matters for SigV4-signing and
///    request-replay debugging.
struct Lease: Codable, Sendable {
    struct Metadata: Codable, Sendable {
        let name: String
        let namespace: String
        let resourceVersion: String?
    }
    struct Spec: Codable, Sendable {
        let holderIdentity: String
        let leaseDurationSeconds: Int?
        let renewTime: String?
        let acquireTime: String?

        init(
            holderIdentity: String,
            leaseDurationSeconds: Int?,
            renewTime: String?,
            acquireTime: String? = nil
        ) {
            self.holderIdentity = holderIdentity
            self.leaseDurationSeconds = leaseDurationSeconds
            self.renewTime = renewTime
            self.acquireTime = acquireTime
        }
    }

    let apiVersion: String
    let kind: String
    let metadata: Metadata
    let spec: Spec

    init(metadata: Metadata, spec: Spec) {
        self.apiVersion = "coordination.k8s.io/v1"
        self.kind = "Lease"
        self.metadata = metadata
        self.spec = spec
    }
}

public enum LockError: Error, LocalizedError, Sendable {
    case acquireFailed(String)
    case leaseLost(String)

    public var errorDescription: String? {
        switch self {
        case .acquireFailed(let n): "Failed to acquire lock '\(n)'"
        case .leaseLost(let n): "Lease '\(n)' was lost"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .acquireFailed:
            "Another instance currently holds the lease, or the Kubernetes API rejected the request. Check `kubectl get lease -n <ns>` and retry after the current holder's TTL expires."
        case .leaseLost:
            "The lease was taken over by another holder during a renew. Usually means your process paused long enough for the TTL to expire — shorten the renew interval or investigate the pause."
        }
    }
}
