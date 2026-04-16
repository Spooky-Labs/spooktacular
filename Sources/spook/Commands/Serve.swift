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

        @Option(name: .customLong("tls-cert"), help: "Path to a PEM-encoded TLS certificate file.")
        var tlsCert: String?

        @Option(name: .customLong("tls-key"), help: "Path to a PEM-encoded TLS private key file.")
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

            // Validate flag combinations.
            let hasCert = tlsCert != nil
            let hasKey = tlsKey != nil
            if hasCert != hasKey {
                print(Style.error("Both --tls-cert and --tls-key must be provided together."))
                throw ExitCode.failure
            }
            if insecure && hasCert {
                print(Style.error("--insecure and TLS flags (--tls-cert, --tls-key) are mutually exclusive."))
                throw ExitCode.failure
            }

            // Load TLS identity when certificate and key are provided.
            var tlsOptions: NWProtocolTLS.Options?
            if let certPath = tlsCert, let keyPath = tlsKey {
                let identity = try Self.loadTLSIdentity(certPath: certPath, keyPath: keyPath)
                let options = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(
                    options.securityProtocolOptions,
                    sec_identity_create(identity)!
                )
                tlsOptions = options
            }

            // Wire enterprise stack from environment variables
            let env = ProcessInfo.processInfo.environment

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

            // Distributed lock (for multi-instance coordination)
            let lockDir = env["SPOOK_LOCK_DIR"]
            if lockDir != nil || tenancyMode == .multiTenant {
                let lock = FileDistributedLock(lockDir: lockDir)
                if let lease = try? await lock.acquire(
                    name: "spook-serve-\(port)",
                    holder: ProcessInfo.processInfo.hostName,
                    duration: 300
                ) {
                    print(Style.info("Acquired lock: \(lease.name)"))
                } else {
                    print(Style.error("Another spook serve instance holds the lock. Use a different port or wait."))
                    throw ExitCode.failure
                }
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
                guard let keyPath = env["SPOOK_AUDIT_SIGNING_KEY"] else {
                    print(Style.error("✗ SPOOK_AUDIT_MERKLE=1 requires SPOOK_AUDIT_SIGNING_KEY to point at a persistent key path."))
                    print(Style.dim("  Without a stable key, signed tree heads don't verify across restarts."))
                    throw ExitCode.failure
                }
                let key = try AuditSinkFactory.loadOrCreateSigningKey(at: keyPath)
                auditSink = MerkleAuditSink(wrapping: base, signingKey: key)
            } else {
                auditSink = auditBase
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

            // If SecItemImport gave us a SecCertificate directly, use it.
            let cert: SecCertificate
            if let directCert = certificate as! SecCertificate? {
                cert = directCert
            } else {
                guard let derData = Self.pemToDER(certPEM),
                      let fallbackCert = SecCertificateCreateWithData(nil, derData as CFData) else {
                    throw TLSLoadingError.invalidCertificate(certPath)
                }
                cert = fallbackCert
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

            let privateKey = key as! SecKey

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
enum TLSLoadingError: Error, LocalizedError {

    /// The PEM certificate file could not be parsed.
    case invalidCertificate(String)

    /// The PEM private key file could not be parsed.
    case invalidPrivateKey(String)

    /// A Security.framework keychain operation failed.
    case keychainError(OSStatus)

    /// `SecIdentityCreateWithCertificate` failed to pair the
    /// certificate with its private key.
    case identityCreationFailed(OSStatus)

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
        }
    }
}
