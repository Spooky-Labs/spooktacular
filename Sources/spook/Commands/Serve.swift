import ArgumentParser
import CryptoKit
import Foundation
import Network
import Security
import SpooktacularKit

extension Spook {

    /// Starts an HTTP API server for managing VMs programmatically.
    ///
    /// The server exposes a RESTful JSON API for listing, creating,
    /// starting, stopping, and deleting virtual machines. It binds to
    /// localhost by default.
    ///
    /// TLS can be enabled by providing PEM-encoded certificate and
    /// private key files via `--tls-cert` and `--tls-key`. When TLS
    /// is not configured and no `SPOOK_API_TOKEN` is set, use
    /// `--insecure` to acknowledge the risk of running without
    /// authentication or encryption.
    ///
    /// ## Endpoints
    ///
    /// | Method | Path | Description |
    /// |--------|------|-------------|
    /// | `GET` | `/health` | Health check |
    /// | `GET` | `/v1/vms` | List all VMs |
    /// | `GET` | `/v1/vms/:name` | Get VM details |
    /// | `POST` | `/v1/vms` | Create a new VM (requires IPSW; prefer clone) |
    /// | `POST` | `/v1/vms/:name/clone` | Clone a VM from a base image |
    /// | `POST` | `/v1/vms/:name/start` | Start a VM |
    /// | `POST` | `/v1/vms/:name/stop` | Stop a VM |
    /// | `DELETE` | `/v1/vms/:name` | Delete a VM |
    /// | `GET` | `/v1/vms/:name/ip` | Resolve VM IP |
    struct Serve: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start an HTTP API server for VM management.",
            discussion: """
                Starts a lightweight HTTP API server that exposes \
                RESTful endpoints for managing virtual machines \
                programmatically. The server binds to localhost by \
                default.

                TLS is enabled by providing --tls-cert and --tls-key \
                with PEM-encoded certificate and private key files. \
                When TLS is not configured and no SPOOK_API_TOKEN is \
                set, pass --insecure to run without authentication.

                The server responds with JSON in a consistent format:
                  {"status": "ok", "data": {...}}
                  {"status": "error", "message": "..."}

                EXAMPLES:
                  spook serve
                  spook serve --port 9090
                  spook serve --host 0.0.0.0 --port 8484
                  spook serve --tls-cert cert.pem --tls-key key.pem
                  spook serve --insecure
                """
        )

        @Option(help: "TCP port to listen on.")
        var port: Int = Int(HTTPAPIServer.defaultPort)

        @Option(help: "Host address to bind to. Use 0.0.0.0 for all interfaces.")
        var host: String = "127.0.0.1"

        @Option(help: "Path to the spook binary for spawning VM processes.")
        var spookPath: String = ProcessInfo.processInfo.environment["SPOOK_PATH"] ?? HTTPAPIServer.defaultSpookPath

        @Option(name: .customLong("tls-cert"),
                help: "Path to a PEM-encoded TLS certificate file. Falls back to SPOOK_TLS_CERT_PATH.")
        var tlsCert: String?

        @Option(name: .customLong("tls-key"),
                help: "Path to a PEM-encoded TLS private key file. Falls back to SPOOK_TLS_KEY_PATH.")
        var tlsKey: String?

        @Flag(help: "Run without TLS or a required API token. Not recommended for production.")
        var insecure: Bool = false

        @Flag(
            name: .customLong("watch-certs"),
            help: "Watch TLS certificate and key files for changes and reload automatically. Defaults to true when TLS is enabled."
        )
        var watchCerts: Bool = false

        func run() async throws {
            try SpooktacularPaths.ensureDirectories()

            guard port > 0 && port <= 65535 else {
                print(Style.error("Invalid port \(port). Must be between 1 and 65535."))
                throw ExitCode.failure
            }

            // CLI flags win, but fall back to the env-var names
            // documented in docs/DEPLOYMENT_HARDENING.md so the
            // reference LaunchDaemon plist actually produces a TLS
            // listener. Before this fallback, the plist's env vars
            // were silently ignored and `spook serve` either bound
            // plaintext or died with `tlsRequired` — either way, a
            // documented-happy-path regression.
            let env = ProcessInfo.processInfo.environment
            let resolvedTLSCert = tlsCert ?? env["SPOOK_TLS_CERT_PATH"]
            let resolvedTLSKey  = tlsKey  ?? env["SPOOK_TLS_KEY_PATH"]

            // Validate flag combinations.
            let hasCert = resolvedTLSCert != nil
            let hasKey = resolvedTLSKey != nil
            if hasCert != hasKey {
                print(Style.error("Both --tls-cert and --tls-key (or SPOOK_TLS_CERT_PATH / SPOOK_TLS_KEY_PATH) must be provided together."))
                throw ExitCode.failure
            }
            if insecure && hasCert {
                print(Style.error("--insecure and TLS configuration are mutually exclusive."))
                throw ExitCode.failure
            }

            // Load TLS identity when certificate and key are provided.
            //
            // `NWProtocolTLS.Options()` defaults to a TLS 1.0 floor on
            // macOS. We pin **1.3** here explicitly so the server-side
            // listener can't quietly negotiate a weaker version than
            // what we advertise. URLSession-side (the client) already
            // enforces 1.3 in `KeychainTLSProvider`, but that's a
            // separate control surface.
            var tlsOptions: NWProtocolTLS.Options?
            if let certPath = resolvedTLSCert, let keyPath = resolvedTLSKey {
                let identity = try Self.loadTLSIdentity(certPath: certPath, keyPath: keyPath)
                let options = NWProtocolTLS.Options()
                sec_protocol_options_set_min_tls_protocol_version(
                    options.securityProtocolOptions, .TLSv13
                )
                sec_protocol_options_set_local_identity(
                    options.securityProtocolOptions,
                    sec_identity_create(identity)!
                )
                tlsOptions = options
            }

            // Tenancy mode
            let tenancyMode: TenancyMode = env["SPOOK_TENANCY_MODE"] == "multi-tenant"
                ? .multiTenant : .singleTenant

            // Tenant isolation
            let isolation: any TenantIsolationPolicy
            if tenancyMode == .multiTenant {
                if let configPath = env["SPOOK_TENANT_CONFIG"],
                   let data = try? Data(contentsOf: URL(filePath: configPath)) {
                    struct TC: Codable { let tenantPools: [String: [String]]; let breakGlassTenants: [String]? }
                    if let tc = try? JSONDecoder().decode(TC.self, from: data) {
                        var pools: [TenantID: Swift.Set<HostPoolID>] = [:]
                        for (k, v) in tc.tenantPools { pools[TenantID(k)] = Swift.Set(v.map { HostPoolID($0) }) }
                        let bg = Swift.Set((tc.breakGlassTenants ?? []).map { TenantID($0) })
                        isolation = MultiTenantIsolation(tenantPools: pools, breakGlassTenants: bg)
                    } else {
                        isolation = MultiTenantIsolation(tenantPools: [:])
                    }
                } else {
                    isolation = MultiTenantIsolation(tenantPools: [:])
                }
            } else {
                isolation = SingleTenantIsolation()
            }

            // RBAC
            // Passing the env var as-is: unset → nil → default
            // path (~/.spooktacular/rbac.json); explicit empty
            // string → in-memory only; any other value → that
            // path. Handles operator intent without silent data
            // loss on restart.
            let roleStore = try JSONRoleStore(configPath: env["SPOOK_RBAC_CONFIG"])
            let authService: (any AuthorizationService)?
            if !insecure {
                if tenancyMode == .multiTenant {
                    authService = MultiTenantAuthorization(
                        policy: .multiTenant, isolation: isolation, roleStore: roleStore
                    )
                } else {
                    authService = SingleTenantAuthorization(
                        policy: .singleTenant, roleStore: roleStore
                    )
                }
            } else {
                authService = nil
            }

            // IdP registry
            if let idpPath = env["SPOOK_IDP_CONFIG"],
               let idpData = try? Data(contentsOf: URL(filePath: idpPath)) {
                struct IdPFile: Codable { let providers: [IdPConfig] }
                if let config = try? JSONDecoder().decode(IdPFile.self, from: idpData) {
                    print(Style.info("Loaded \(config.providers.count) identity provider(s)"))
                }
            }

            // Distributed lock (for multi-instance coordination).
            //
            // Selection is driven by `DistributedLockFactory` which
            // reads the environment — `SPOOK_DYNAMO_TABLE` picks the
            // cross-region DynamoDB backend, `SPOOK_K8S_API` picks
            // Kubernetes Leases, otherwise falls back to file/NFS
            // flock. We engage the factory whenever the operator has
            // explicitly opted into a shared backend OR when running
            // multi-tenant (where coordination is mandatory).
            let dynamoSelected = env["SPOOK_DYNAMO_TABLE"]?.isEmpty == false
            let k8sSelected = env["SPOOK_K8S_API"]?.isEmpty == false
            let fileLockSelected = env["SPOOK_LOCK_DIR"] != nil
            var distributedLockBuilt: DistributedLockFactory.Built?
            if dynamoSelected || k8sSelected || fileLockSelected || tenancyMode == .multiTenant {
                let built = try DistributedLockFactory.makeFromEnvironment(environment: env)
                print(Style.info("Distributed lock backend: \(built.backend)"))
                if let lease = try? await built.lock.acquire(
                    name: "spook-serve-\(port)",
                    holder: ProcessInfo.processInfo.hostName,
                    duration: 300
                ) {
                    print(Style.info("Acquired lock: \(lease.name)"))
                } else {
                    print(Style.error("Another spook serve instance holds the lock. Use a different port or wait."))
                    throw ExitCode.failure
                }
                distributedLockBuilt = built
            }

            // Audit sink chain
            var auditBase: (any AuditSink)?
            if let auditPath = env["SPOOK_AUDIT_FILE"] {
                auditBase = try JSONFileAuditSink(path: auditPath)
            }
            if let immutablePath = env["SPOOK_AUDIT_IMMUTABLE_PATH"] {
                let immutable = try AppendOnlyFileAuditStore(path: immutablePath)
                if let base = auditBase {
                    auditBase = DualAuditSink(primary: base, secondary: immutable)
                } else {
                    auditBase = immutable
                }
            }
            let auditSink: (any AuditSink)?
            if env["SPOOK_AUDIT_MERKLE"] == "1", let base = auditBase {
                let auditConfig = AuditConfig(
                    merkleEnabled: true,
                    merkleSigningKeyLabel: env["SPOOK_AUDIT_SIGNING_KEY_LABEL"],
                    merkleSigningKeyPath: env["SPOOK_AUDIT_SIGNING_KEY_PATH"]
                )
                let signer: any P256Signer
                do {
                    signer = try await AuditSinkFactory.resolveMerkleSigner(config: auditConfig)
                } catch let err as AuditSinkFactoryError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    throw ExitCode.failure
                } catch let err as KeyStoreError {
                    print(Style.error("✗ \(err.localizedDescription)"))
                    if let hint = err.recoverySuggestion { print(Style.dim("  \(hint)")) }
                    throw ExitCode.failure
                }
                auditSink = MerkleAuditSink(wrapping: base, signer: signer)
            } else {
                auditSink = auditBase
            }

            // Production preflight — refuse to start when a
            // multi-tenant deployment is missing controls the
            // enterprise review specifically flagged as
            // "deployments that should fail fast." This gate is
            // in addition to the TLS / bearer-token check inside
            // `HTTPAPIServer.init`; it catches the combinations
            // that would otherwise pass the listener's gate but
            // still leave the fleet unmonitored or un-authorized.
            let preflight = ProductionPreflight(
                tenancyMode: tenancyMode,
                insecure: insecure,
                hasAuthorizationService: authService != nil,
                hasAuditSink: auditSink != nil,
                hasDistributedLockService: distributedLockBuilt != nil
            )
            do {
                try preflight.validate()
            } catch let error as ProductionPreflightError {
                print(Style.error(error.localizedDescription))
                if let suggestion = error.recoverySuggestion {
                    print(Style.dim(suggestion))
                }
                throw ExitCode.failure
            }

            // Signed-request verifier — the production auth path.
            // Walks SPOOK_API_PUBLIC_KEYS_DIR for PEM files;
            // each one authorises one caller identity (operator
            // workstation, controller instance, CI runner, etc.).
            //
            // File naming convention: `<identity>.pem` — the
            // filename stem (minus `.pem`) becomes the actor
            // identity string used in RBAC + audit records. A
            // fallback fingerprint-based identity is used for
            // files that don't follow the convention.
            var sigVerifier: SignedRequestVerifier?
            var actorIdentityByFingerprint: [String: String] = [:]
            if let keysDir = env["SPOOK_API_PUBLIC_KEYS_DIR"] {
                let fm = FileManager.default
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: keysDir, isDirectory: &isDir), isDir.boolValue,
                   let names = try? fm.contentsOfDirectory(atPath: keysDir) {
                    var keys: [P256.Signing.PublicKey] = []
                    for name in names where name.hasSuffix(".pem") || name.hasSuffix(".pub") {
                        let path = (keysDir as NSString).appendingPathComponent(name)
                        guard let pem = try? String(contentsOfFile: path, encoding: .utf8),
                              let key = try? P256.Signing.PublicKey(pemRepresentation: pem) else {
                            print(Style.warning("Skipping unreadable / malformed key: \(name)"))
                            continue
                        }
                        keys.append(key)
                        // Derive identity from filename stem.
                        let stem = (name as NSString).deletingPathExtension
                        let fingerprint = SignedRequestVerifier.hexSHA256(key.x963Representation)
                        actorIdentityByFingerprint[fingerprint] = stem
                    }
                    if !keys.isEmpty {
                        sigVerifier = SignedRequestVerifier(trustedKeys: keys)
                        print(Style.info("Loaded \(keys.count) trusted caller public key(s) from \(keysDir)"))
                    } else {
                        print(Style.warning("SPOOK_API_PUBLIC_KEYS_DIR at '\(keysDir)' has no valid PEMs"))
                    }
                } else {
                    print(Style.warning("SPOOK_API_PUBLIC_KEYS_DIR at '\(keysDir)' is not a directory"))
                }
            }

            // Workload-identity OIDC issuer. When both
            // SPOOK_OIDC_ISSUER_URL and an SEP / PEM signing key
            // are configured, spook serves as a federated
            // identity provider for its managed VMs — operators
            // can bind IAM roles to VMs and workloads inside
            // the VM get short-lived AWS/GCP/Azure credentials
            // via standard OIDC federation (sts:AssumeRoleWithWebIdentity).
            var oidcIssuer: WorkloadTokenIssuer?
            if let issuerURL = env["SPOOK_OIDC_ISSUER_URL"] {
                let signer: (any P256Signer)?
                if let label = env["SPOOK_OIDC_ISSUER_KEY_LABEL"] {
                    // SEP-bound (recommended).
                    do {
                        signer = try await P256KeyStore.loadOrCreateSEP(
                            service: P256KeyStore.Service.oidcIssuer,
                            label: label,
                            presenceGated: false
                        )
                    } catch {
                        print(Style.error("✗ Cannot load OIDC issuer SEP key: \(error.localizedDescription)"))
                        throw ExitCode.failure
                    }
                } else if let path = env["SPOOK_OIDC_ISSUER_KEY_PATH"] {
                    // Software fallback for non-SEP hosts.
                    do {
                        signer = try P256KeyStore.loadOrCreateSoftware(at: path)
                    } catch {
                        print(Style.error("✗ Cannot load OIDC issuer software key: \(error.localizedDescription)"))
                        throw ExitCode.failure
                    }
                } else {
                    print(Style.warning("SPOOK_OIDC_ISSUER_URL is set but neither SPOOK_OIDC_ISSUER_KEY_LABEL (SEP-bound, recommended) nor SPOOK_OIDC_ISSUER_KEY_PATH (software) is configured — workload federation disabled."))
                    signer = nil
                }
                if let signer {
                    oidcIssuer = WorkloadTokenIssuer(issuerURL: issuerURL, signer: signer)
                    print(Style.info("Workload-identity OIDC issuer enabled: \(issuerURL) (kid: \(oidcIssuer!.kid))"))
                }
            }

            // Host-identity signing key. Used whenever this
            // control plane speaks to a guest agent (vsock
            // signed requests). Distinct from the OIDC issuer
            // key (rotation is independent; no trust overlap).
            //
            // SPOOK_HOST_IDENTITY_KEY_LABEL selects the SEP
            // label; otherwise we use "default". Daemon use —
            // no presence gate. The public key is logged at
            // startup so operators know what to install in each
            // agent's SPOOK_HOST_PUBLIC_KEYS_DIR trust
            // directory.
            let hostKeyLabel = env["SPOOK_HOST_IDENTITY_KEY_LABEL"] ?? "default"
            do {
                let hostSigner = try await P256KeyStore.loadOrCreateSEP(
                    service: P256KeyStore.Service.hostIdentity,
                    label: hostKeyLabel,
                    presenceGated: false
                )
                let fingerprint = SignedRequestVerifier.hexSHA256(
                    hostSigner.publicKey.x963Representation
                )
                print(Style.info("Host identity: service=\(P256KeyStore.Service.hostIdentity) label=\(hostKeyLabel) fingerprint=\(String(fingerprint.prefix(16)))…"))
                print(Style.dim("  Host public key (install into each agent's SPOOK_HOST_PUBLIC_KEYS_DIR):"))
                print(hostSigner.publicKey.pemRepresentation)
            } catch {
                // Host identity is advisory at this point — we
                // log the failure but don't block startup. The
                // OIDC + API signed-request paths remain
                // functional; only agent-bound operations would
                // be affected.
                print(Style.warning("Host-identity key unavailable: \(error.localizedDescription) — agent-bound operations will fail until resolved."))
            }

            // OpenTelemetry exporter. When SPOOK_OTLP_ENDPOINT
            // is set, every API request emits an OTLP-HTTP-JSON
            // span to the configured collector (Grafana Tempo,
            // Honeycomb, Datadog APM, AWS X-Ray via ADOT, etc.).
            // Absent endpoint → no-op. Export is best-effort;
            // collector stalls never back up the API path.
            let otelExporter: (any OTelExporter)?
            if let endpointStr = env["SPOOK_OTLP_ENDPOINT"],
               let endpoint = URL(string: endpointStr) {
                let headers = env["SPOOK_OTLP_HEADERS"]
                    .flatMap(parseOTLPHeaders) ?? [:]
                otelExporter = OTLPHTTPJSONExporter(config: .init(
                    endpoint: endpoint,
                    serviceName: env["SPOOK_OTLP_SERVICE_NAME"] ?? "spooktacular",
                    extraHeaders: headers
                ))
                print(Style.info("OpenTelemetry traces → \(endpoint)"))
            } else {
                otelExporter = nil
            }

            // VM → IAM role bindings. Loaded alongside tenancy
            // / RBAC config so the IAM CRUD endpoints have a
            // persistent store. Absence is non-fatal — the
            // /v1/iam endpoints return 404 and the
            // /v1/vms/:name/identity-token path refuses to mint.
            let iamBindingStore: (any VMIAMBindingStore)?
            do {
                iamBindingStore = try JSONVMIAMBindingStore(
                    configPath: env["SPOOK_IAM_BINDINGS_CONFIG"]
                )
            } catch {
                print(Style.warning("IAM binding store unavailable: \(error.localizedDescription). `spook iam` endpoints disabled."))
                iamBindingStore = nil
            }

            let server: HTTPAPIServer
            do {
                server = try HTTPAPIServer(
                    host: host,
                    port: UInt16(port),
                    vmDirectory: SpooktacularPaths.vms,
                    spookPath: spookPath,
                    tlsOptions: tlsOptions,
                    authService: authService,
                    auditSink: auditSink,
                    signatureVerifier: sigVerifier,
                    actorIdentityByKeyFingerprint: actorIdentityByFingerprint,
                    tokenIssuer: oidcIssuer,
                    iamBindingStore: iamBindingStore,
                    otelExporter: otelExporter,
                    insecureMode: insecure
                )
            } catch let error as HTTPAPIServerError {
                print(Style.error(error.localizedDescription))
                if let suggestion = error.recoverySuggestion {
                    print(Style.dim(suggestion))
                }
                throw ExitCode.failure
            } catch {
                print(Style.error("Failed to create server: \(error.localizedDescription)"))
                throw ExitCode.failure
            }

            let shutdownServer = server
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler {
                    let sigName = sig == SIGTERM ? "SIGTERM" : "SIGINT"
                    print("\nReceived \(sigName) — shutting down API server...")
                    Task {
                        await shutdownServer.stop()
                        Foundation.exit(0)
                    }
                }
                source.resume()
            }

            let scheme = tlsOptions != nil ? "https" : "http"

            print(Style.bold("Spooktacular HTTP API Server"))
            print()
            Style.field("Endpoint", "\(scheme)://\(host):\(port)")
            if tlsOptions != nil {
                Style.field("TLS", "enabled")
            }
            if insecure {
                print()
                print(Style.warning("WARNING: Running in insecure mode — no TLS, no required API token."))
                print(Style.warning("Do NOT expose this server to untrusted networks."))
            }
            Style.field("VM directory", Style.dim(SpooktacularPaths.vms.path))
            print()
            print(Style.dim("Press Ctrl+C to stop."))
            print()

            do {
                try await server.start()
            } catch {
                print(Style.error("Server failed to start: \(error.localizedDescription)"))
                throw ExitCode.failure
            }

            // Enable TLS certificate file watching when TLS is active
            // and --watch-certs is set (or implied by TLS being enabled).
            let shouldWatch = watchCerts || (tlsCert != nil && tlsKey != nil)
            if shouldWatch, let certPath = tlsCert, let keyPath = tlsKey {
                do {
                    try await server.watchCertificates(
                        certPath: certPath,
                        keyPath: keyPath,
                        loadIdentity: { cert, key in
                            try Self.loadTLSIdentity(certPath: cert, keyPath: key)
                        }
                    )
                    Style.field("Certificate watching", "enabled")
                } catch {
                    print(Style.error("Failed to watch TLS certificates: \(error.localizedDescription)"))
                    throw ExitCode.failure
                }
            }

            try await Task.sleep(for: .seconds(Double(Int.max)))
        }

        // MARK: - TLS Identity Loading

        /// Loads a TLS identity from PEM-encoded certificate and private
        /// key files using Security.framework.
        ///
        /// - Parameters:
        ///   - certPath: Absolute or relative path to the PEM certificate file.
        ///   - keyPath: Absolute or relative path to the PEM private key file.
        /// - Returns: A `SecIdentity` combining the certificate and key.
        /// - Throws: An error if the files cannot be read or the identity
        ///   cannot be created.
        private static func loadTLSIdentity(certPath: String, keyPath: String) throws -> SecIdentity {
            // Read PEM files.
            let certURL = URL(filePath: certPath)
            let keyURL = URL(filePath: keyPath)

            let certPEM = try Data(contentsOf: certURL)
            let keyPEM = try Data(contentsOf: keyURL)

            // Import the certificate and key as PKCS#12 by converting
            // through Security.framework's import functions.
            var importedItems: CFArray?

            // Import certificate.
            let certStatus = SecItemImport(
                certPEM as CFData,
                "pem" as CFString,
                nil,
                nil,
                [],
                nil,
                nil,
                &importedItems
            )

            guard certStatus == errSecSuccess,
                  let certItems = importedItems as? [Any],
                  let certificate = certItems.first
            else {
                // Fallback: try DER-decoding from PEM content.
                guard let derData = Self.pemToDER(certPEM),
                      let cert = SecCertificateCreateWithData(nil, derData as CFData) else {
                    throw TLSLoadingError.invalidCertificate(certPath)
                }
                // Import private key and create identity with the DER certificate.
                let identity = try Self.createIdentity(
                    certificate: cert,
                    keyPEM: keyPEM,
                    keyPath: keyPath
                )
                return identity
            }

            // If `SecItemImport` returned a `SecCertificate`, use it
            // directly. Otherwise — some PEMs come back as other
            // CF types (e.g. `SecIdentity`) depending on input shape
            // — fall through to DER-decoding as a clean second path.
            //
            // `CFGetTypeID` + `SecCertificateGetTypeID` is the Apple-
            // documented way to type-check a `CFTypeRef`. See
            // https://developer.apple.com/documentation/security/seccertificate .
            // Swift's `as?` from `CFTypeRef` to a CoreFoundation
            // subclass always succeeds (it checks the Obj-C class,
            // not the CF type id), so the type-id comparison is the
            // check that actually matters, and `unsafeBitCast` under
            // a verified guard is the standard Swift idiom for the
            // narrowing step. No trap is possible — a failing
            // type-id check maps to the DER-decoding fallback.
            let cert: SecCertificate
            if CFGetTypeID(certificate as CFTypeRef) == SecCertificateGetTypeID() {
                cert = unsafeBitCast(certificate as AnyObject, to: SecCertificate.self)
            } else if let derData = Self.pemToDER(certPEM),
                      let fallbackCert = SecCertificateCreateWithData(nil, derData as CFData) {
                cert = fallbackCert
            } else {
                throw TLSLoadingError.invalidTLSMaterial(
                    path: certPath,
                    reason: "SecItemImport returned a non-SecCertificate reference and the PEM could not be DER-decoded."
                )
            }

            return try Self.createIdentity(certificate: cert, keyPEM: keyPEM, keyPath: keyPath)
        }

        /// Creates a `SecIdentity` from a certificate and PEM-encoded private key.
        private static func createIdentity(
            certificate: SecCertificate,
            keyPEM: Data,
            keyPath: String
        ) throws -> SecIdentity {
            // Import the private key.
            var keyItems: CFArray?
            let keyStatus = SecItemImport(
                keyPEM as CFData,
                "pem" as CFString,
                nil,
                nil,
                [],
                nil,
                nil,
                &keyItems
            )

            guard keyStatus == errSecSuccess,
                  let items = keyItems as? [Any],
                  let key = items.first
            else {
                throw TLSLoadingError.invalidPrivateKey(keyPath)
            }

            // Type-check the imported object against `SecKeyGetTypeID`
            // before narrowing — `SecItemImport` theoretically could
            // return a different class (identity, certificate) for a
            // malformed PEM, and a force-cast would DoS the server
            // on a first-run TLS path that ingests user-supplied
            // files. Documented pattern at
            // https://developer.apple.com/documentation/security/seckey .
            // Same CFTypeRef narrowing dance as the certificate
            // branch above — `as?` on CF types bypasses the type-id
            // check, so we verify the type id ourselves and bridge
            // with `unsafeBitCast`.
            guard CFGetTypeID(key as CFTypeRef) == SecKeyGetTypeID() else {
                throw TLSLoadingError.invalidTLSMaterial(
                    path: keyPath,
                    reason: "SecItemImport returned a non-SecKey reference for the private key PEM."
                )
            }
            let privateKey: SecKey = unsafeBitCast(key as AnyObject, to: SecKey.self)

            // Add items to the temporary keychain so
            // SecIdentityCreateWithCertificate can find the pair.
            let addCertQuery: [String: Any] = [
                kSecClass as String: kSecClassCertificate,
                kSecValueRef as String: certificate,
            ]
            SecItemDelete(addCertQuery as CFDictionary)
            let certAddStatus = SecItemAdd(addCertQuery as CFDictionary, nil)
            if certAddStatus != errSecSuccess && certAddStatus != errSecDuplicateItem {
                throw TLSLoadingError.keychainError(certAddStatus)
            }

            let addKeyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecValueRef as String: privateKey,
            ]
            SecItemDelete(addKeyQuery as CFDictionary)
            let keyAddStatus = SecItemAdd(addKeyQuery as CFDictionary, nil)
            if keyAddStatus != errSecSuccess && keyAddStatus != errSecDuplicateItem {
                throw TLSLoadingError.keychainError(keyAddStatus)
            }

            // Use SecIdentityCreateWithCertificate on macOS.
            var identityRef: SecIdentity?
            let idStatus = SecIdentityCreateWithCertificate(nil, certificate, &identityRef)
            guard idStatus == errSecSuccess, let identity = identityRef else {
                throw TLSLoadingError.identityCreationFailed(idStatus)
            }

            return identity
        }

        /// Strips PEM headers/footers and decodes the Base64 payload to DER data.
        private static func pemToDER(_ pem: Data) -> Data? {
            guard let pemString = String(data: pem, encoding: .utf8) else {
                return nil
            }
            let lines = pemString.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            let base64 = lines.joined()
            return Data(base64Encoded: base64)
        }
    }
}

// MARK: - TLS Loading Errors

/// Errors that can occur when loading TLS certificates and keys from PEM files.
enum TLSLoadingError: Error, LocalizedError, Equatable {

    /// The PEM certificate file could not be parsed.
    case invalidCertificate(String)

    /// The PEM private key file could not be parsed.
    case invalidPrivateKey(String)

    /// A Security.framework keychain operation failed.
    case keychainError(OSStatus)

    /// `SecIdentityCreateWithCertificate` failed to pair the
    /// certificate with its private key.
    case identityCreationFailed(OSStatus)

    /// `SecItemImport` returned a CF object whose dynamic type
    /// is not the expected `SecCertificate` / `SecKey`. Surfaced
    /// as a typed error instead of a trapping force-cast so a
    /// malformed user-supplied PEM cannot DoS the server.
    case invalidTLSMaterial(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidCertificate(let path):
            "Failed to load TLS certificate from '\(path)'."
        case .invalidPrivateKey(let path):
            "Failed to load TLS private key from '\(path)'."
        case .keychainError(let status):
            "Keychain operation failed (OSStatus \(status))."
        case .identityCreationFailed(let status):
            "Failed to create TLS identity from certificate and key (OSStatus \(status))."
        case .invalidTLSMaterial(let path, let reason):
            "TLS material at '\(path)' was not in the expected CF class: \(reason)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .invalidCertificate:
            "Ensure the file is a valid PEM-encoded X.509 certificate."
        case .invalidPrivateKey:
            "Ensure the file is a valid PEM-encoded private key (RSA or EC)."
        case .keychainError:
            "Check that the certificate and key are valid and not corrupted."
        case .identityCreationFailed:
            "Ensure the private key matches the certificate. Generate a new pair if needed."
        case .invalidTLSMaterial:
            "Confirm the PEM is a plain X.509 certificate / PKCS#8 private key — not a bundle, trust store, or PKCS#12 archive. Regenerate with `openssl x509 -in cert.pem -outform PEM` if unsure."
        }
    }
}

/// Parses `Header1: val1; Header2: val2` — the env-var shape
/// for OTLP extra headers (authorization tokens, tenant IDs).
/// Silently ignores malformed entries.
private func parseOTLPHeaders(_ raw: String) -> [String: String] {
    var result: [String: String] = [:]
    for entry in raw.split(separator: ";") {
        let parts = entry.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let name = parts[0].trimmingCharacters(in: .whitespaces)
        let value = parts[1].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty && !value.isEmpty else { continue }
        result[name] = value
    }
    return result
}
