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

    /// Opens a streaming watch, returning an async stream of watch events.
    func watchVMs(resourceVersion: String) -> AsyncThrowingStream<WatchEvent, Error> {
        let url = crdURL(query: "watch=true&resourceVersion=\(resourceVersion)&allowWatchBookmarks=true")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 0

        return AsyncThrowingStream { continuation in
            let task = session.dataTask(with: req) { data, _, error in
                if let error { continuation.finish(throwing: error); return }
                guard let data, !data.isEmpty else { continuation.finish(); return }
                for line in data.split(separator: UInt8(ascii: "\n")) {
                    do {
                        continuation.yield(try JSONDecoder().decode(WatchEvent.self, from: Data(line)))
                    } catch {
                        continuation.finish(throwing: error); return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
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

    // MARK: - Helpers

    private func crdURL(name: String? = nil, subresource: String? = nil, query: String? = nil) -> URL {
        var path = "/apis/spooktacular.app/v1alpha1/namespaces/\(namespace)/macosvms"
        if let name { path += "/\(name)" }
        if let subresource { path += "/\(subresource)" }
        if let query { path += "?\(query)" }
        return baseURL.appendingPathComponent(path)
    }

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

    private static func readFile(_ path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path),
              let string = String(data: data, encoding: .utf8)
        else { throw ControllerError.missingFile(path) }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - TLS Delegate

/// Trusts the cluster CA for in-pod TLS verification.
private final class ClusterTLSDelegate: NSObject, URLSessionDelegate, Sendable {
    private let caPath: String
    init(caPath: String) { self.caPath = caPath }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { completionHandler(.performDefaultHandling, nil); return }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
