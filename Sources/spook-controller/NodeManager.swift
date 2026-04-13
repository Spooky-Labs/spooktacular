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
    private let labelSelector: String
    private let session = URLSession(configuration: .ephemeral)
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "node-mgr")

    init(apiPort: UInt16 = 8484, labelSelector: String = "spooktacular.app/role=mac-host") {
        self.apiPort = apiPort
        self.labelSelector = labelSelector
    }

    // MARK: - Discovery

    /// Refreshes the node list from the Kubernetes API.
    func refreshNodes(using client: KubernetesClient) async {
        let baseURL = client.baseURL
        let encodedSelector = labelSelector.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? labelSelector
        let url = baseURL.appendingPathComponent("/api/v1/nodes")
            .appending(queryItems: [URLQueryItem(name: "labelSelector", value: encodedSelector)])

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            let tokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
            if let tokenData = FileManager.default.contents(atPath: tokenPath),
               let token = String(data: tokenData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (data, _) = try await session.data(for: request)
            let nodeList = try JSONDecoder().decode(K8sNodeList.self, from: data)

            var discovered: [String: NodeEndpoint] = [:]
            for node in nodeList.items {
                let name = node.metadata.name
                guard let ip = node.status?.addresses?.first(where: { $0.type == "InternalIP" })?.address,
                      let apiURL = URL(string: "http://\(ip):\(apiPort)")
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
                let (_, response) = try await session.data(for: request)
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

// MARK: - Kubernetes Node Types

private struct K8sNodeList: Decodable { let items: [K8sNode] }
private struct K8sNode: Decodable { let metadata: K8sNodeMeta; let status: K8sNodeStatus? }
private struct K8sNodeMeta: Decodable { let name: String }
private struct K8sNodeStatus: Decodable { let addresses: [K8sNodeAddress]? }
private struct K8sNodeAddress: Decodable { let type: String; let address: String }
