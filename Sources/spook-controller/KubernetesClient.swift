/// A minimal Kubernetes API client using URLSession.
///
/// Authenticates via in-cluster service account credentials and connects
/// to the API server at `KUBERNETES_SERVICE_HOST:KUBERNETES_SERVICE_PORT`.
/// Supports list, watch (streaming), and merge-patch for status updates.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import os

// MARK: - KubernetesClient

actor KubernetesClient {

    let baseURL: URL
    private let token: String
    let namespace: String
    private let session: URLSession
    private let tlsDelegate: ClusterTLSDelegate
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "k8s-client")

    private static let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
    private static let caPath = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    private static let namespacePath = "/var/run/secrets/kubernetes.io/serviceaccount/namespace"

    // MARK: - Initialization

    /// Creates a client from in-cluster service account credentials.
    init() throws {
        guard let host = ProcessInfo.processInfo.environment["KUBERNETES_SERVICE_HOST"],
              let portString = ProcessInfo.processInfo.environment["KUBERNETES_SERVICE_PORT"],
              !host.isEmpty, !portString.isEmpty
        else {
            throw ControllerError.missingEnvironment("KUBERNETES_SERVICE_HOST / KUBERNETES_SERVICE_PORT")
        }

        let hostPart = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "https://\(hostPart):\(portString)") else {
            throw ControllerError.invalidURL("https://\(hostPart):\(portString)")
        }
        self.baseURL = url
        self.token = try Self.readFile(Self.tokenPath)
        self.namespace = (try? Self.readFile(Self.namespacePath)) ?? "default"
        self.tlsDelegate = ClusterTLSDelegate(caPath: Self.caPath)
        self.session = URLSession(configuration: .ephemeral, delegate: tlsDelegate, delegateQueue: nil)

        logger.notice("K8s client: \(url.absoluteString, privacy: .public), ns=\(self.namespace, privacy: .public)")
    }

    /// Creates a client with explicit parameters (testing / out-of-cluster).
    init(baseURL: URL, token: String, namespace: String) {
        self.baseURL = baseURL
        self.token = token
        self.namespace = namespace
        self.tlsDelegate = ClusterTLSDelegate(caPath: Self.caPath)
        self.session = URLSession(configuration: .ephemeral, delegate: tlsDelegate, delegateQueue: nil)
    }

    // MARK: - List

    /// Lists all MacOSVM resources in the configured namespace.
    func listVMs() async throws -> MacOSVMList {
        let data = try await request(url: crdURL(), method: "GET")
        return try JSONDecoder().decode(MacOSVMList.self, from: data)
    }

    // MARK: - Watch

    /// Opens a streaming watch, yielding events line-by-line as they arrive.
    ///
    /// Uses `URLSession.bytes(for:)` so events stream in real time instead of
    /// buffering the entire response. A 410 Gone finishes the stream cleanly;
    /// the reconciler loop will re-list and restart the watch.
    func watchVMs(resourceVersion: String) -> AsyncThrowingStream<WatchEvent, Error> {
        let url = crdURL(query: "watch=true&resourceVersion=\(resourceVersion)&allowWatchBookmarks=true")

        return AsyncThrowingStream { continuation in
            let task = Task { [session, token] in
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.timeoutInterval = 0

                let (bytes, response) = try await session.bytes(for: req)

                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 410 {
                        continuation.finish()
                        return
                    }
                    if !(200..<300).contains(http.statusCode) {
                        throw ControllerError.apiError("Watch returned HTTP \(http.statusCode)")
                    }
                }

                for try await line in bytes.lines {
                    guard !line.isEmpty else { continue }
                    guard let data = line.data(using: .utf8) else { continue }
                    let event = try JSONDecoder().decode(WatchEvent.self, from: data)
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Patch Status

    /// Updates the status subresource via merge-patch.
    func updateStatus(name: String, status: MacOSVMStatus) async throws {
        let url = crdURL(name: name, subresource: "status")
        let patch: [String: Any] = [
            "status": [
                "phase": status.phase.rawValue,
                "ip": status.ip as Any,
                "nodeName": status.nodeName as Any,
                "message": status.message as Any,
            ].compactMapValues { $0 }
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/merge-patch+json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: patch)

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ControllerError.apiError("PATCH status/\(name) failed: HTTP \(code)")
        }
        logger.debug("Updated status '\(name, privacy: .public)': \(status.phase.rawValue, privacy: .public)")
    }

    // MARK: - Nodes

    /// Lists nodes matching a label selector.
    func listNodes(labelSelector: String) async throws -> [K8sNode] {
        let encoded = labelSelector.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? labelSelector
        let url = baseURL.appendingPathComponent("/api/v1/nodes?labelSelector=\(encoded)")
        let data = try await request(url: url, method: "GET")
        return try JSONDecoder().decode(K8sNodeList.self, from: data).items
    }

    // MARK: - Patch

    /// Sends a merge-patch to the named MacOSVM resource.
    func mergePatch(name: String, body: Data) async throws {
        let url = crdURL(name: name)
        try await request(url: url, method: "PATCH", body: body, contentType: "application/merge-patch+json")
    }

    // MARK: - Lease

    /// Attempts to acquire or renew a coordination Lease with optimistic concurrency.
    ///
    /// - If the lease exists and is held by another identity that hasn't expired, backs off.
    /// - If the lease exists and is held by self or has expired, updates with `resourceVersion`.
    /// - If PUT returns 409 Conflict, backs off.
    /// - If the lease doesn't exist, creates it via POST.
    /// - `acquireTime` is only set on initial acquisition, not on renewals.
    func upsertLease(name: String, holderIdentity: String, durationSeconds: Int) async throws -> Bool {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let nowString = formatter.string(from: now)
        let url = baseURL.appendingPathComponent(
            "/apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases/\(name)")

        // Step 1: Try to GET the existing lease.
        var existingData: Data?
        do {
            existingData = try await request(url: url, method: "GET")
        } catch {
            // 404 means no lease exists — fall through to POST.
            existingData = nil
        }

        if let existingData,
           let json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
           let metadata = json["metadata"] as? [String: Any],
           let resourceVersion = metadata["resourceVersion"] as? String {
            let spec = json["spec"] as? [String: Any] ?? [:]
            let existingHolder = spec["holderIdentity"] as? String
            let renewTimeString = spec["renewTime"] as? String
            let existingAcquireTime = spec["acquireTime"] as? String

            // Step 2: If held by another identity and not expired, back off.
            if let existingHolder, existingHolder != holderIdentity {
                if let renewTimeString, let renewTime = formatter.date(from: renewTimeString) {
                    let expiresAt = renewTime.addingTimeInterval(TimeInterval(durationSeconds))
                    if expiresAt > now {
                        logger.info("Lease '\(name, privacy: .public)' held by '\(existingHolder, privacy: .public)', not expired — backing off")
                        return false
                    }
                } else {
                    // No renewTime means we can't verify expiry — back off to be safe.
                    return false
                }
            }

            // Step 3: Holder == self OR lease is expired — PUT with resourceVersion.
            let isRenewal = existingHolder == holderIdentity
            var updateSpec: [String: Any] = [
                "holderIdentity": holderIdentity,
                "leaseDurationSeconds": durationSeconds,
                "renewTime": nowString,
            ]
            // Preserve acquireTime on renewals; set it on new acquisitions.
            if isRenewal, let existingAcquireTime {
                updateSpec["acquireTime"] = existingAcquireTime
            } else {
                updateSpec["acquireTime"] = nowString
            }

            let putBody: [String: Any] = [
                "apiVersion": "coordination.k8s.io/v1",
                "kind": "Lease",
                "metadata": ["name": name, "namespace": namespace, "resourceVersion": resourceVersion],
                "spec": updateSpec,
            ]
            let putData = try JSONSerialization.data(withJSONObject: putBody)

            do {
                try await request(url: url, method: "PUT", body: putData, contentType: "application/json")
                return true
            } catch let error as ControllerError {
                // Step 4: 409 Conflict means another writer updated — back off.
                if case .apiError(let msg) = error, msg.contains("HTTP 409") {
                    logger.info("Lease '\(name, privacy: .public)' conflict on PUT — backing off")
                    return false
                }
                throw error
            }
        }

        // Step 5: Lease doesn't exist — POST to create.
        let createBody: [String: Any] = [
            "apiVersion": "coordination.k8s.io/v1",
            "kind": "Lease",
            "metadata": ["name": name, "namespace": namespace],
            "spec": [
                "holderIdentity": holderIdentity,
                "leaseDurationSeconds": durationSeconds,
                "acquireTime": nowString,
                "renewTime": nowString,
            ],
        ]
        let createData = try JSONSerialization.data(withJSONObject: createBody)
        let createURL = baseURL.appendingPathComponent(
            "/apis/coordination.k8s.io/v1/namespaces/\(namespace)/leases")

        do {
            try await request(url: createURL, method: "POST", body: createData, contentType: "application/json")
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func request(url: URL, method: String, body: Data? = nil, contentType: String? = nil) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let msg = String(data: data, encoding: .utf8) ?? "no body"
            throw ControllerError.apiError("\(method) \(url.path) HTTP \(code): \(msg)")
        }
        return data
    }

    // MARK: - Helpers

    private func crdURL(name: String? = nil, subresource: String? = nil, query: String? = nil) -> URL {
        var path = "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/macosvms"
        if let name { path += "/\(name)" }
        if let subresource { path += "/\(subresource)" }
        if let query { path += "?\(query)" }
        return baseURL.appendingPathComponent(path)
    }

    private static func readFile(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let string = String(data: data, encoding: .utf8)
        else { throw ControllerError.missingFile(path) }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Kubernetes Node Types

struct K8sNodeList: Decodable { let items: [K8sNode] }
struct K8sNode: Decodable { let metadata: K8sNodeMeta; let status: K8sNodeStatus? }
struct K8sNodeMeta: Decodable { let name: String }
struct K8sNodeStatus: Decodable { let addresses: [K8sNodeAddress]? }
struct K8sNodeAddress: Decodable { let type: String; let address: String }

// MARK: - TLS Delegate

/// Trusts the cluster CA for in-pod TLS verification.
///
/// Loads the service-account CA certificate at init, sets it as the sole
/// trust anchor, and only accepts the server if `SecTrustEvaluateWithError`
/// passes. Falls back to default handling when the CA file is missing.
private final class ClusterTLSDelegate: NSObject, URLSessionDelegate, Sendable {

    private let caCertificates: [SecCertificate]

    init(caPath: String) {
        if let data = FileManager.default.contents(atPath: caPath) {
            caCertificates = Self.loadCertificates(from: data)
        } else {
            caCertificates = []
        }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { completionHandler(.performDefaultHandling, nil); return }

        // If the cluster CA file is missing (empty secret, volume not
        // yet mounted, future config change), we previously fell back
        // to `.performDefaultHandling`, which silently trusts the
        // system root store. That turns into a full MITM bypass if a
        // misconfigured or adversarially-modified cluster presents a
        // cert chained to a public root CA. Fail closed instead — no
        // pinned CA ⇒ no connection.
        guard !caCertificates.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        SecTrustSetAnchorCertificates(trust, caCertificates as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)

        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Parses PEM data into an array of `SecCertificate`.
    private static func loadCertificates(from data: Data) -> [SecCertificate] {
        guard let pem = String(data: data, encoding: .utf8) else { return [] }
        var certs: [SecCertificate] = []
        let blocks = pem.components(separatedBy: "-----BEGIN CERTIFICATE-----")
        for block in blocks {
            guard let endRange = block.range(of: "-----END CERTIFICATE-----") else { continue }
            let base64 = block[block.startIndex..<endRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: "")
            guard let der = Data(base64Encoded: base64),
                  let cert = SecCertificateCreateWithData(nil, der as CFData)
            else { continue }
            certs.append(cert)
        }
        return certs
    }
}
