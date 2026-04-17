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

    public init(apiURL: URL, namespace: String, session: URLSession = .shared, token: String? = nil) {
        self.apiURL = apiURL
        self.namespace = namespace
        self.session = session
        self.token = token
    }

    public func acquire(name: String, holder: String, duration: TimeInterval) async throws -> DistributedLease? {
        // GET the lease. If it doesn't exist or is expired, create/update it.
        let url = apiURL.appendingPathComponent(
            "apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases/\(name)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addAuth(&request)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if status == 404 {
            // Lease doesn't exist, create it
            return try await createLease(name: name, holder: holder, duration: duration)
        }

        guard status == 200 else { return nil }

        // Parse existing lease
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let spec = json["spec"] as? [String: Any],
              let currentHolder = spec["holderIdentity"] as? String
        else { return nil }

        // Check if expired
        if let renewTime = spec["renewTime"] as? String,
           let leaseDuration = spec["leaseDurationSeconds"] as? Int,
           let renewed = try? Date(renewTime, strategy: .iso8601) {
            let expires = renewed.addingTimeInterval(TimeInterval(leaseDuration))
            if Date() < expires && currentHolder != holder {
                return nil // Held by someone else, not expired
            }
        }

        // Expired or held by us — update
        let resourceVersion = (json["metadata"] as? [String: Any])?["resourceVersion"] as? String
        return try await updateLease(
            name: name, holder: holder, duration: duration, resourceVersion: resourceVersion)
    }

    public func renew(_ lease: DistributedLease, duration: TimeInterval) async throws -> DistributedLease {
        guard let updated = try await acquire(name: lease.name, holder: lease.holder, duration: duration) else {
            throw LockError.leaseLost(lease.name)
        }
        return updated
    }

    public func release(_ lease: DistributedLease) async throws {
        let url = apiURL.appendingPathComponent(
            "apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases/\(lease.name)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        addAuth(&request)
        _ = try await session.data(for: request)
    }

    private func createLease(
        name: String, holder: String, duration: TimeInterval
    ) async throws -> DistributedLease {
        let url = apiURL.appendingPathComponent(
            "apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases")
        let body: [String: Any] = [
            "apiVersion": "coordination.k8s.io/v1",
            "kind": "Lease",
            "metadata": ["name": name, "namespace": namespace],
            "spec": [
                "holderIdentity": holder,
                "leaseDurationSeconds": Int(duration),
                "renewTime": Date().ISO8601Format(),
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        let url = apiURL.appendingPathComponent(
            "apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases/\(name)")
        var meta: [String: Any] = ["name": name, "namespace": namespace]
        if let rv = resourceVersion { meta["resourceVersion"] = rv }
        let body: [String: Any] = [
            "apiVersion": "coordination.k8s.io/v1",
            "kind": "Lease",
            "metadata": meta,
            "spec": [
                "holderIdentity": holder,
                "leaseDurationSeconds": Int(duration),
                "renewTime": Date().ISO8601Format(),
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        addAuth(&request)

        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LockError.acquireFailed(name)
        }
        return DistributedLease(name: name, holder: holder, duration: duration)
    }

    private func addAuth(_ request: inout URLRequest) {
        if let t = token { request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
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
}
