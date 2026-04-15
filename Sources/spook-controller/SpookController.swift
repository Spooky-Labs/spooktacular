/// The Spooktacular Kubernetes controller entry point.
///
/// Watches `MacOSVM` custom resources and reconciles them by calling
/// the Spooktacular HTTP API (`spook serve`) on Mac nodes. Runs as a
/// Deployment on a Linux node in the K8s cluster.
///
/// ## Configuration (Environment Variables)
///
/// | Variable | Default | Description |
/// |----------|---------|-------------|
/// | `WATCH_NAMESPACE` | (service account) | Namespace to watch |
/// | `NODE_LABEL_SELECTOR` | `spooktacular.app/role=mac-host` | Mac node selector |
/// | `NODE_API_PORT` | `8484` | Port for `spook serve` |
/// | `HEALTH_CHECK_INTERVAL` | `30` | Seconds between health checks |
/// | `SPOOK_TENANCY_MODE` | `single-tenant` | `single-tenant` or `multi-tenant` |
/// | `SPOOK_TENANT_CONFIG` | (none) | Path to JSON tenant-pool mapping file |
/// | `SPOOK_AUDIT_MERKLE` | (none) | Set to `1` to enable Merkle audit sink |
/// | `SPOOK_AUDIT_SIGNING_KEY` | (none) | Path to Ed25519 signing key for Merkle audit |

import Foundation
import CryptoKit
import os
import SpookCore
import SpookApplication
import SpookInfrastructureApple

// MARK: - Entry Point

@main
struct SpookController {

    private static let logger = Logger(subsystem: "com.spooktacular.controller", category: "main")

    static func main() async {
        logger.notice("spook-controller starting")

        let env = ProcessInfo.processInfo.environment
        let labelSelector = env["NODE_LABEL_SELECTOR"] ?? "spooktacular.app/role=mac-host"
        let apiPort = UInt16(env["NODE_API_PORT"] ?? "") ?? 8484
        let healthInterval = UInt64(env["HEALTH_CHECK_INTERVAL"] ?? "") ?? 30

        let client: KubernetesClient
        do {
            client = try KubernetesClient()
        } catch {
            logger.fault("Failed to create K8s client: \(error.localizedDescription, privacy: .public)")
            return
        }

        let namespace = env["WATCH_NAMESPACE"] ?? client.namespace
        logger.notice("Watching ns=\(namespace, privacy: .public), selector=\(labelSelector, privacy: .public)")

        // Tenancy mode: determines authorization, isolation, and reuse policies.
        let tenancyMode: TenancyMode
        switch env["SPOOK_TENANCY_MODE"] ?? "single-tenant" {
        case "multi-tenant":
            tenancyMode = .multiTenant
            logger.notice("Tenancy mode: multi-tenant")
        default:
            tenancyMode = .singleTenant
            logger.notice("Tenancy mode: single-tenant")
        }

        let reusePolicy = ReusePolicy.default(for: tenancyMode)

        // Load tenant-pool mapping from SPOOK_TENANT_CONFIG file or environment
        let tenantConfig: TenantConfig?
        let tenantPools: [TenantID: Set<HostPoolID>]
        if let configPath = env["SPOOK_TENANT_CONFIG"],
           let configData = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let config = try? JSONDecoder().decode(TenantConfig.self, from: configData) {
            tenantConfig = config
            var pools: [TenantID: Set<HostPoolID>] = [:]
            for (key, value) in config.tenantPools {
                pools[TenantID(key)] = Set(value.map { HostPoolID($0) })
            }
            tenantPools = pools
            logger.notice("Loaded tenant config from \(configPath, privacy: .public): \(tenantPools.count) tenants")
        } else {
            tenantConfig = nil
            tenantPools = [:]
            if tenancyMode == .multiTenant {
                logger.warning("Multi-tenant mode but no SPOOK_TENANT_CONFIG — all tenants will use default pool")
            }
        }

        let breakGlassTenants = Set((tenantConfig?.breakGlassTenants ?? []).map { TenantID($0) })
        let isolation: any TenantIsolationPolicy = tenancyMode == .singleTenant
            ? SingleTenantIsolation()
            : MultiTenantIsolation(tenantPools: tenantPools, breakGlassTenants: breakGlassTenants)
        let authService: any AuthorizationService = tenancyMode == .singleTenant
            ? SingleTenantAuthorization(policy: reusePolicy)
            : MultiTenantAuthorization(policy: reusePolicy, isolation: isolation)

        // Create audit sinks
        let auditSink: any AuditSink
        if let auditPath = env["SPOOK_AUDIT_FILE"] {
            do {
                auditSink = try JSONFileAuditSink(path: auditPath)
                logger.notice("Audit sink: JSONL file at \(auditPath, privacy: .public)")
            } catch {
                logger.fault("Failed to create audit file at \(auditPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            auditSink = OSLogAuditSink()
            logger.notice("Audit sink: os.Logger (use SPOOK_AUDIT_FILE for SIEM export)")
        }

        // Load TLS identity for mTLS with Mac nodes.
        // Required in production. Use SPOOK_INSECURE_CONTROLLER=1 to bypass
        // (development only — logs a prominent warning).
        let insecure = env["SPOOK_INSECURE_CONTROLLER"] == "1"
        let tlsProvider: KeychainTLSProvider?

        if let certPath = env["TLS_CERT_PATH"],
           let keyPath = env["TLS_KEY_PATH"],
           let caPath = env["TLS_CA_PATH"] {
            do {
                tlsProvider = try KeychainTLSProvider(certPath: certPath, keyPath: keyPath, caPath: caPath)
                logger.notice("mTLS enabled: controller will present client certificate to nodes")
            } catch {
                logger.fault("Failed to load TLS identity: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else if insecure {
            tlsProvider = nil
            logger.warning("⚠️  INSECURE MODE: No mTLS configured. Controller-to-node traffic is NOT authenticated. Do NOT use in production.")
        } else {
            logger.fault("mTLS is required. Set TLS_CERT_PATH, TLS_KEY_PATH, and TLS_CA_PATH, or set SPOOK_INSECURE_CONTROLLER=1 for development.")
            return
        }

        let nodeManager: NodeManager
        let reconciler: Reconciler
        if let tls = tlsProvider {
            nodeManager = NodeManager(apiPort: apiPort, labelSelector: labelSelector, tlsProvider: tls)
            reconciler = Reconciler(client: client, nodeManager: nodeManager, tlsProvider: tls)
        } else {
            nodeManager = NodeManager(apiPort: apiPort, labelSelector: labelSelector, insecure: true)
            reconciler = Reconciler(client: client, nodeManager: nodeManager, insecure: true)
        }
        let poolManager = RunnerPoolManager()
        let poolReconciler = RunnerPoolReconciler(
            client: client,
            manager: poolManager,
            nodeManager: nodeManager,
            tenancyMode: tenancyMode,
            authService: authService,
            isolation: isolation,
            reusePolicy: reusePolicy,
            auditSink: auditSink
        )
        let shutdownSignal = ShutdownSignal()
        let leaderElection = LeaderElection(client: client, leaseName: "spook-controller")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await leaderElection.run {
                    await reconciler.run()
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(healthInterval))
                    await nodeManager.checkHealth()
                }
            }
            group.addTask {
                await poolReconciler.run()
            }
            group.addTask {
                await shutdownSignal.wait()
                logger.notice("Shutdown signal received")
            }
            // First task to finish (shutdown signal) triggers cancellation.
            await group.next()
            group.cancelAll()
        }

        logger.notice("spook-controller stopped")
    }
}

// MARK: - Leader Election

/// Lease-based leader election. Acquires a coordination Lease, renews every
/// 10 seconds, and runs the provided work closure only while this instance
/// holds the lease. If renewal fails, cancels work and re-competes.
actor LeaderElection {

    private let client: KubernetesClient
    private let leaseName: String
    private let identity: String
    private let renewInterval: Duration = .seconds(10)
    private let leaseDuration = 15
    private let logger = Logger(subsystem: "com.spooktacular.controller", category: "leader")

    init(client: KubernetesClient, leaseName: String) {
        self.client = client
        self.leaseName = leaseName
        self.identity = ProcessInfo.processInfo.environment["HOSTNAME"]
            ?? UUID().uuidString.prefix(8).lowercased()
    }

    /// Competes for the lease, then runs `work`. Retries on loss.
    func run(work: @escaping @Sendable () async -> Void) async {
        while !Task.isCancelled {
            guard await acquire() else {
                logger.info("Lease not acquired, retrying in \(self.leaseDuration)s")
                try? await Task.sleep(for: .seconds(leaseDuration))
                continue
            }

            logger.notice("Acquired lease '\(self.leaseName, privacy: .public)' as \(self.identity, privacy: .public)")
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await work(); return true }
                group.addTask { await self.renewLoop(); return false }
                // When renewLoop exits (lease lost), cancel the work task.
                if let finished = await group.next(), !finished {
                    group.cancelAll()
                    logger.warning("Lost lease, stopping reconciler")
                }
            }
        }
    }

    private func acquire() async -> Bool {
        (try? await client.upsertLease(
            name: leaseName, holderIdentity: String(identity), durationSeconds: leaseDuration)) ?? false
    }

    private func renewLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: renewInterval)
            guard await acquire() else { return }
            logger.debug("Renewed lease '\(self.leaseName, privacy: .public)'")
        }
    }
}

// MARK: - ShutdownSignal

/// Bridges POSIX signals (SIGTERM, SIGINT) into Swift concurrency.
final class ShutdownSignal: Sendable {

    private let continuation: AsyncStream<Void>.Continuation
    private let stream: AsyncStream<Void>
    nonisolated(unsafe) private let sources: [any DispatchSourceProtocol]

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.stream = stream
        self.continuation = continuation

        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSource.setEventHandler { continuation.yield() }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        intSource.setEventHandler { continuation.yield() }
        intSource.resume()

        self.sources = [termSource, intSource]
    }

    func wait() async {
        for await _ in stream { return }
    }
}

// MARK: - Errors

/// Errors specific to the controller.
enum ControllerError: Error, LocalizedError, Sendable {
    case missingEnvironment(String)
    case missingFile(String)
    case invalidURL(String)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .missingEnvironment(let v): "Missing environment: \(v)"
        case .missingFile(let p):        "Missing file: \(p)"
        case .invalidURL(let u):         "Invalid URL: \(u)"
        case .apiError(let m):           "K8s API error: \(m)"
        }
    }
}

// MARK: - Tenant Configuration

/// JSON configuration for tenant-to-pool mapping.
///
/// Load from `SPOOK_TENANT_CONFIG` file path. Example:
/// ```json
/// {
///   "tenantPools": {
///     "team-a": ["pool-1"],
///     "team-b": ["pool-2"]
///   },
///   "breakGlassTenants": ["team-a"]
/// }
/// ```
private struct TenantConfig: Codable {
    let tenantPools: [String: [String]]
    let breakGlassTenants: [String]?
}
