/// Discovers and tracks Mac nodes running `spook serve`.
///
/// Queries the Kubernetes API for nodes labeled `spooktacular.app/role=mac-host`,
/// extracts InternalIP addresses, and provides HTTP endpoint URLs for the
/// Spooktacular API on each node (port 8484 by default).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import os
import SpooktacularKit

// MARK: - NodeEndpoint

/// A Mac node's connection details.
struct NodeEndpoint: Sendable {
    let name: String
    let apiURL: URL
    var healthy: Bool
}

// MARK: - NodeManager

actor NodeManager {

    private var nodes: [String: NodeEndpoint] = [:]
    private let apiPort: UInt16
    private let scheme: String
    private let labelSelector: String
    private let healthSession: URLSession
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "node-mgr")

    /// Creates a node manager.
    ///
    /// - Parameters:
    ///   - apiPort: Port where `spook serve` listens on each node.
    ///   - scheme: URL scheme for node API calls. Defaults to the value of
    ///     the `NODE_API_SCHEME` environment variable, falling back to `"https"`.
    ///   - labelSelector: Kubernetes label selector for Mac host nodes.
    ///   - tlsProvider: ``TLSIdentityProvider`` for mutual TLS. Required
    ///     in production — the controller must present a client certificate
    ///     and pin the node's CA. Pass `nil` only in development with
    ///     `SPOOK_INSECURE_CONTROLLER=1`. Bearer token authentication is
    ///     retained as a secondary auth layer (defense in depth).
    init(
        apiPort: UInt16 = 8484,
        scheme: String = ProcessInfo.processInfo.environment["NODE_API_SCHEME"] ?? "https",
        labelSelector: String = "spooktacular.app/role=mac-host",
        tlsProvider: (any TLSIdentityProvider)? = nil
    ) {
        self.apiPort = apiPort
        self.scheme = scheme
        self.labelSelector = labelSelector
        self.healthSession = tlsProvider?.configuredSession()
            ?? URLSession(configuration: .ephemeral)
    }

    // MARK: - Discovery

    /// Refreshes the node list from the Kubernetes API via the shared client.
    func refreshNodes(using client: KubernetesClient) async {
        do {
            let k8sNodes = try await client.listNodes(labelSelector: labelSelector)

            var discovered: [String: NodeEndpoint] = [:]
            for node in k8sNodes {
                let name = node.metadata.name
                guard let ip = node.status?.addresses?.first(where: { $0.type == "InternalIP" })?.address,
                      let apiURL = URL(string: "\(scheme)://\(ip):\(apiPort)")
                else { continue }
                discovered[name] = NodeEndpoint(name: name, apiURL: apiURL, healthy: true)
            }

            nodes = discovered
            logger.notice("Discovered \(discovered.count) Mac node(s): \(discovered.keys.sorted().joined(separator: ", "), privacy: .public)")
        } catch {
            logger.error("Failed to refresh nodes: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Lookup

    func endpoint(for nodeName: String) -> NodeEndpoint? { nodes[nodeName] }
    func healthyNodes() -> [NodeEndpoint] { nodes.values.filter(\.healthy) }

    // MARK: - Health Checks

    /// Pings every known node's `/health` endpoint and updates status.
    func checkHealth() async {
        for (name, var endpoint) in nodes {
            let healthURL = endpoint.apiURL.appendingPathComponent("/health")
            var request = URLRequest(url: healthURL)
            request.timeoutInterval = 5
            do {
                let (_, response) = try await healthSession.data(for: request)
                endpoint.healthy = ((response as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } ?? false
            } catch {
                endpoint.healthy = false
            }
            if !endpoint.healthy {
                logger.warning("Node '\(name, privacy: .public)' health check failed")
            }
            nodes[name] = endpoint
        }
    }
}
