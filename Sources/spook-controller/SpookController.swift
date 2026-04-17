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
           let configData = try? Data(contentsOf: URL(filePath: configPath)),
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
        // RBAC: load role store for resource-level authorization (OWASP deny-by-default)
        let roleStore: any RoleStore
        do {
            roleStore = try JSONRoleStore(configPath: env["SPOOK_RBAC_CONFIG"])
            logger.notice("RBAC enabled: \(env["SPOOK_RBAC_CONFIG"] ?? "built-in roles")")
        } catch {
            logger.fault("Failed to load RBAC config: \(error.localizedDescription, privacy: .public)")
            return
        }

        let authService: any AuthorizationService = tenancyMode == .singleTenant
            ? SingleTenantAuthorization(policy: reusePolicy, roleStore: roleStore)
            : MultiTenantAuthorization(policy: reusePolicy, isolation: isolation, roleStore: roleStore)

        // Create audit sink chain:
        // Base sink → optional immutable store → optional Merkle tree → final sink
        var baseSink: any AuditSink
        if let auditPath = env["SPOOK_AUDIT_FILE"] {
            do {
                baseSink = try JSONFileAuditSink(path: auditPath)
                logger.notice("Audit sink: JSONL file at \(auditPath, privacy: .public)")
            } catch {
                logger.fault("Failed to create audit file: \(error.localizedDescription, privacy: .public)")
                return
            }
        } else {
            baseSink = OSLogAuditSink()
            logger.notice("Audit sink: os.Logger (use SPOOK_AUDIT_FILE for SIEM export)")
        }

        // Immutable append-only store (SPOOK_AUDIT_IMMUTABLE_PATH)
        if let immutablePath = env["SPOOK_AUDIT_IMMUTABLE_PATH"] {
            do {
                let immutableStore = try AppendOnlyFileAuditStore(path: immutablePath)
                // Wrap: records go to both the base sink AND the immutable store
                baseSink = DualAuditSink(primary: baseSink, secondary: immutableStore)
                logger.notice("Immutable audit store: \(immutablePath, privacy: .public) (UF_APPEND)")
            } catch {
                logger.warning("Failed to create immutable audit store: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Merkle tree tamper-evidence (auto in multi-tenant, or SPOOK_AUDIT_MERKLE=1).
        //
        // The signing key path is mandatory — tree heads must
        // verify across process restarts or the non-repudiation
        // story collapses. Refuse to boot with Merkle enabled but
        // no key path configured; a loud startup failure is
        // strictly better than silently signing with an ephemeral
        // key.
        let auditSink: any AuditSink
        if tenancyMode == .multiTenant || env["SPOOK_AUDIT_MERKLE"] == "1" {
            guard let keyPath = env["SPOOK_AUDIT_SIGNING_KEY"] else {
                logger.fault("Merkle audit requires SPOOK_AUDIT_SIGNING_KEY to point at a persistent signing key path. Aborting.")
                exit(1)
            }
            let signingKey: Curve25519.Signing.PrivateKey
            do {
                signingKey = try AuditSinkFactory.loadOrCreateSigningKey(at: keyPath)
            } catch {
                logger.fault("Cannot load Merkle signing key at \(keyPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                exit(1)
            }
            auditSink = MerkleAuditSink(wrapping: baseSink, signingKey: signingKey)
            logger.notice("Audit: Merkle tree enabled (RFC 6962 tamper-evidence), key=\(keyPath, privacy: .public)")
        } else {
            auditSink = baseSink
        }

        // IdP registry (SPOOK_IDP_CONFIG)
        let idpVerifier: MultiIdPVerifier = MultiIdPVerifier()
        if let idpPath = env["SPOOK_IDP_CONFIG"],
           let idpData = try? Data(contentsOf: URL(filePath: idpPath)) {
            struct IdPFileConfig: Codable { let providers: [IdPConfig] }
            if let config = try? JSONDecoder().decode(IdPFileConfig.self, from: idpData) {
                for provider in config.providers {
                    switch provider {
                    case .oidc(let oidcConfig):
                        let verifier = OIDCTokenVerifier(config: oidcConfig, http: URLSessionHTTPClient())
                        await idpVerifier.register(issuer: oidcConfig.issuerURL, verifier: verifier)
                    case .saml(let samlConfig):
                        if let verifier = try? SAMLAssertionVerifier(config: samlConfig) {
                            await idpVerifier.register(issuer: samlConfig.entityID, verifier: verifier)
                        }
                    }
                }
                logger.notice("IdP registry: loaded \(config.providers.count) provider(s) from \(idpPath, privacy: .public)")
            }
        }

        // Load TLS identity for mTLS with Mac nodes.
        // Required in production. Use SPOOK_INSECURE_CONTROLLER=1 to bypass
        // (development only — logs a prominent warning).
        let insecure = env["SPOOK_INSECURE_CONTROLLER"] == "1"
        let tlsProvider: KeychainTLSProvider?

        // Accept the canonical `SPOOK_`-prefixed names documented in
        // DEPLOYMENT_HARDENING.md; fall back to the legacy
        // un-prefixed names so in-place upgrades don't break.
        let certPath = env["SPOOK_TLS_CERT_PATH"] ?? env["TLS_CERT_PATH"]
        let keyPath  = env["SPOOK_TLS_KEY_PATH"]  ?? env["TLS_KEY_PATH"]
        let caPath   = env["SPOOK_TLS_CA_PATH"]   ?? env["TLS_CA_PATH"]
        if let certPath, let keyPath, let caPath {
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
            logger.fault("mTLS is required. Set SPOOK_TLS_CERT_PATH, SPOOK_TLS_KEY_PATH, and SPOOK_TLS_CA_PATH, or set SPOOK_INSECURE_CONTROLLER=1 for development.")
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

        // Fair-share scheduler — activated when the operator
        // sets both SPOOK_SCHEDULER_POLICY (path to a JSON
        // policy file) and SPOOK_FLEET_CAPACITY (total VM
        // slots). Either unset → fall through to per-pool
        // independent scaling, which is the documented
        // single-tenant / single-team posture.
        let (fairScheduler, fleetCapacity) = Self.loadFairScheduler(env: env)
        if let fairScheduler {
            logger.notice(
                "Fair-share scheduler active: \(fairScheduler.policies.count) policies, fleet capacity \(fleetCapacity)"
            )
        }

        let poolReconciler = RunnerPoolReconciler(
            client: client,
            manager: poolManager,
            nodeManager: nodeManager,
            tenancyMode: tenancyMode,
            authService: authService,
            isolation: isolation,
            reusePolicy: reusePolicy,
            auditSink: auditSink,
            fairScheduler: fairScheduler,
            fleetCapacity: fleetCapacity
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

    // MARK: - Fair-share configuration

    /// Loads the FairScheduler + fleet capacity from the
    /// environment. Both env vars must be present for the
    /// scheduler to be active — silently enabling fair-share on
    /// half-configured hosts would reshape scheduling behavior
    /// in ways operators didn't opt into.
    ///
    /// `SPOOK_SCHEDULER_POLICY` points at a JSON file shaped like:
    ///
    /// ```json
    /// [
    ///   {"tenant": "platform", "weight": 3, "minGuaranteed": 4},
    ///   {"tenant": "mobile",   "weight": 2, "minGuaranteed": 2, "maxCap": 20},
    ///   {"tenant": "data",     "weight": 1, "minGuaranteed": 1}
    /// ]
    /// ```
    ///
    /// `SPOOK_FLEET_CAPACITY` is the integer total of VM slots
    /// across the fleet. For Apple Silicon EC2 Mac hosts with
    /// the kernel's 2-VM limit, this is `hostCount * 2`.
    static func loadFairScheduler(
        env: [String: String]
    ) -> (FairScheduler?, Int) {
        guard let policyPath = env["SPOOK_SCHEDULER_POLICY"],
              !policyPath.isEmpty,
              let capacityRaw = env["SPOOK_FLEET_CAPACITY"],
              let capacity = Int(capacityRaw),
              capacity > 0
        else {
            return (nil, 0)
        }

        struct PolicyFile: Decodable {
            let tenant: String
            let weight: Int
            let minGuaranteed: Int?
            let maxCap: Int?
        }

        guard let data = try? Data(contentsOf: URL(filePath: policyPath)),
              let entries = try? JSONDecoder().decode([PolicyFile].self, from: data)
        else {
            logger.fault(
                "SPOOK_SCHEDULER_POLICY at '\(policyPath, privacy: .public)' missing or malformed — fair-share disabled"
            )
            return (nil, 0)
        }

        let policies = entries.map { entry in
            TenantSchedulingPolicy(
                tenant: TenantID(entry.tenant),
                weight: entry.weight,
                minGuaranteed: entry.minGuaranteed ?? 0,
                maxCap: entry.maxCap
            )
        }
        return (FairScheduler(policies: policies), capacity)
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

    var recoverySuggestion: String? {
        switch self {
        case .missingEnvironment(let v):
            "Set `\(v)` in the controller's Deployment spec. `KUBERNETES_SERVICE_HOST` and `_PORT` are auto-injected by kubelet; if missing, you're not running in-cluster."
        case .missingFile(let p):
            "Expected file at `\(p)`. If this is a ServiceAccount token/CA, ensure the ServiceAccount is mounted (`automountServiceAccountToken: true`) on the Pod spec."
        case .invalidURL:
            "The constructed Kubernetes API URL is invalid. Check that `KUBERNETES_SERVICE_HOST` is a hostname or IPv4/IPv6 literal and `KUBERNETES_SERVICE_PORT` is numeric."
        case .apiError:
            "The K8s API rejected the request. Inspect the controller's ServiceAccount RBAC (`kubectl auth can-i` from the pod); 403s are typically missing verbs on `macosvms` or `runnerpools`."
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
