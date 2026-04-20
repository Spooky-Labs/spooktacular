/// Discovers and tracks Mac nodes running `spook serve`.
///
/// Queries the Kubernetes API for nodes labeled `spooktacular.app/role=mac-host`,
/// extracts InternalIP addresses, and provides HTTPS endpoint URLs for the
/// Spooktacular API on each node (port 8484 by default, TLS required).

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import os
import SpooktacularCore
import SpooktacularApplication
import SpooktacularInfrastructureApple

// MARK: - NodeEndpoint

/// A Mac node's connection details.
/// A Mac node's connection, identity, and scheduling metadata.
///
/// Every scheduling decision filters by ``hostPoolID`` and
/// ``tenantID``. Every control-plane call validates ``expectedIdentity``
/// against the node's TLS certificate.
struct NodeEndpoint: Sendable {
    /// The Kubernetes node name.
    let name: String
    /// The HTTPS API endpoint for `spook serve`.
    let apiURL: URL
    /// Whether the last health check succeeded.
    var healthy: Bool
    /// Expected TLS certificate subject or SAN for this node.
    let expectedIdentity: String?
    /// The host pool this node belongs to.
    let hostPoolID: HostPoolID
    /// The tenant that owns this node (for multi-tenant scheduling).
    let tenantID: TenantID
    /// Whether the node is accepting new VMs.
    var drainState: DrainState
    /// Node labels for scheduling (e.g., pool, gpu, xcode version).
    var labels: [String: String]

    /// Whether the node is draining, active, or in maintenance.
    enum DrainState: String, Sendable {
        case active
        case draining
        case maintenance
    }

    init(
        name: String,
        apiURL: URL,
        healthy: Bool = false,
        expectedIdentity: String? = nil,
        hostPoolID: HostPoolID = .default,
        tenantID: TenantID = .default,
        drainState: DrainState = .active,
        labels: [String: String] = [:]
    ) {
        self.name = name
        self.apiURL = apiURL
        self.healthy = healthy
        self.expectedIdentity = expectedIdentity
        self.hostPoolID = hostPoolID
        self.tenantID = tenantID
        self.drainState = drainState
        self.labels = labels
    }
}

// MARK: - NodeManager

actor NodeManager {

    private var nodes: [String: NodeEndpoint] = [:]
    private let apiPort: UInt16
    private let scheme: String
    private let labelSelector: String
    private let http: any HTTPClient
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
    ///     `SPOOKTACULAR_INSECURE_CONTROLLER=1`. Bearer token authentication is
    ///     retained as a secondary auth layer (defense in depth).
    /// Creates a production node manager with mandatory mTLS.
    ///
    /// - Parameters:
    ///   - apiPort: Port where `spook serve` listens on each node.
    ///   - labelSelector: Kubernetes label selector for Mac host nodes.
    ///   - tlsProvider: TLS identity provider for mutual TLS. Required.
    init(
        apiPort: UInt16 = 8484,
        labelSelector: String = "spooktacular.app/role=mac-host",
        tlsProvider: any TLSIdentityProvider
    ) {
        self.apiPort = apiPort
        self.scheme = "https"
        self.labelSelector = labelSelector
        self.http = tlsProvider.makeHTTPClient()
    }

    /// Creates a development-only node manager without TLS.
    ///
    /// - Important: Do not use in production. This initializer exists
    ///   only for local development and testing.
    init(
        apiPort: UInt16 = 8484,
        scheme: String = "https",
        labelSelector: String = "spooktacular.app/role=mac-host",
        insecure: Bool
    ) {
        precondition(insecure, "Use init(apiPort:labelSelector:tlsProvider:) for production")
        self.apiPort = apiPort
        self.scheme = scheme
        self.labelSelector = labelSelector
        self.http = URLSessionHTTPClient(session: URLSession(configuration: .ephemeral))
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
            do {
                let response = try await http.execute(
                    DomainHTTPRequest(method: .get, url: healthURL, timeout: 5)
                )
                endpoint.healthy = response.isSuccess
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
