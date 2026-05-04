import Foundation
import SpooktacularCore

/// Strongly-typed configuration for Spooktacular deployments.
///
/// Replaces scattered environment variable reads with a single
/// configuration object that can be loaded from a JSON file,
/// environment variables, or constructed programmatically.
///
/// ## Usage
///
/// ```swift
/// // From environment variables
/// let config = SpooktacularConfig.fromEnvironment()
///
/// // From JSON file
/// let config = try SpooktacularConfig.load(from: "/etc/spooktacular/config.json")
/// ```
public struct SpooktacularConfig: Sendable, Codable {

    // MARK: - Tenancy

    /// The deployment tenancy mode.
    public let tenancyMode: TenancyMode

    /// Registered tenants with their host pool assignments.
    public let tenants: [TenantDefinition]

    // MARK: - Security

    /// RBAC configuration.
    public let rbac: RBACConfig

    /// Identity provider configurations.
    public let identityProviders: [IdentityProviderConfig]

    /// TLS configuration.
    public let tls: TLSConfig?

    // MARK: - Audit

    /// Audit logging configuration.
    public let audit: AuditConfig

    // MARK: - Server

    /// API server configuration.
    public let server: ServerConfig

    // MARK: - Init

    public init(
        tenancyMode: TenancyMode = .singleTenant,
        tenants: [TenantDefinition] = [],
        rbac: RBACConfig = .init(),
        identityProviders: [IdentityProviderConfig] = [],
        tls: TLSConfig? = nil,
        audit: AuditConfig = .init(),
        server: ServerConfig = .init()
    ) {
        self.tenancyMode = tenancyMode
        self.tenants = tenants
        self.rbac = rbac
        self.identityProviders = identityProviders
        self.tls = tls
        self.audit = audit
        self.server = server
    }

    /// Loads configuration from environment variables, failing
    /// loudly when values are unparseable.
    ///
    /// Canonical names are `SPOOK_`-prefixed. Historical un-prefixed
    /// aliases (`TLS_CERT_PATH`, `TLS_KEY_PATH`, `TLS_CA_PATH`) are
    /// accepted as a fallback so existing deployments don't break,
    /// but the prefixed form wins when both are set. A future
    /// release may drop the un-prefixed aliases; today's operators
    /// should migrate to `SPOOKTACULAR_TLS_*_PATH`.
    ///
    /// Unknown enum values (e.g. `SPOOKTACULAR_TENANCY_MODE=triple-tenant`)
    /// and non-numeric values where integers are expected throw
    /// ``ConfigParseError`` instead of silently collapsing to a
    /// default. Every resolved value is logged at `.info` on startup
    /// so operators can diff the running process's config against
    /// what they thought they set.
    ///
    /// - Parameter logger: Receives a single `.info` line on success
    ///   summarizing the resolved config. Default is silent; callers
    ///   at the composition root should inject an ``OSLogProvider``
    ///   with category `"config"` so the line appears in Console.app.
    /// - Throws: ``ConfigParseError`` on unparseable input.
    public static func fromEnvironment(
        logger: any LogProvider = SilentLogProvider()
    ) throws -> SpooktacularConfig {
        let env = ProcessInfo.processInfo.environment
        // `SPOOK_` wins, fall back to legacy un-prefixed name.
        func tlsPath(_ prefixed: String, _ legacy: String) -> String? {
            env[prefixed] ?? env[legacy]
        }

        let tenancyMode = try parseTenancyMode(env["SPOOKTACULAR_TENANCY_MODE"])
        let port = try parseUInt16(env["SPOOKTACULAR_PORT"], name: "SPOOKTACULAR_PORT", default: 8484)
        let maxConns = try parseInt(env["SPOOKTACULAR_MAX_CONNECTIONS"], name: "SPOOKTACULAR_MAX_CONNECTIONS", default: 50)
        let rateLimit = try parseInt(env["SPOOKTACULAR_RATE_LIMIT"], name: "SPOOKTACULAR_RATE_LIMIT", default: 120)
        let retentionDays = try parseOptionalInt(
            env["SPOOK_AUDIT_S3_RETENTION_DAYS"] ?? env["SPOOK_AUDIT_S3_LOCK_DAYS"],
            name: "SPOOK_AUDIT_S3_RETENTION_DAYS"
        )
        let batchSize = try parseOptionalInt(
            env["SPOOK_AUDIT_S3_BATCH_SIZE"], name: "SPOOK_AUDIT_S3_BATCH_SIZE"
        )

        let config = SpooktacularConfig(
            tenancyMode: tenancyMode,
            rbac: RBACConfig(configPath: env["SPOOKTACULAR_RBAC_CONFIG"]),
            tls: TLSConfig(
                certPath: tlsPath("SPOOKTACULAR_TLS_CERT_PATH", "TLS_CERT_PATH"),
                keyPath: tlsPath("SPOOKTACULAR_TLS_KEY_PATH", "TLS_KEY_PATH"),
                caPath: tlsPath("SPOOKTACULAR_TLS_CA_PATH", "TLS_CA_PATH")
            ),
            audit: AuditConfig(
                filePath: env["SPOOKTACULAR_AUDIT_FILE"],
                immutablePath: env["SPOOKTACULAR_AUDIT_IMMUTABLE_PATH"],
                merkleEnabled: env["SPOOKTACULAR_AUDIT_MERKLE"] == "1",
                merkleSigningKeyLabel: env["SPOOKTACULAR_AUDIT_SIGNING_KEY_LABEL"],
                s3Bucket: env["SPOOK_AUDIT_S3_BUCKET"],
                s3Region: env["SPOOK_AUDIT_S3_REGION"],
                s3Prefix: env["SPOOK_AUDIT_S3_PREFIX"],
                s3RetentionDays: retentionDays,
                s3BatchSize: batchSize,
                webhookURL: env["SPOOKTACULAR_AUDIT_WEBHOOK_URL"],
                webhookHMACKeyHex: env["SPOOKTACULAR_AUDIT_WEBHOOK_HMAC_KEY_HEX"],
                webhookExtraHeaders: env["SPOOKTACULAR_AUDIT_WEBHOOK_HEADERS"].flatMap(parseHeaders)
            ),
            server: ServerConfig(
                host: env["SPOOKTACULAR_HOST"] ?? "127.0.0.1",
                port: port,
                maxConnections: maxConns,
                rateLimit: rateLimit,
                insecure: env["SPOOKTACULAR_INSECURE_CONTROLLER"] == "1"
            )
        )
        logger.info(
            "config resolved tenancy=\(config.tenancyMode.rawValue) host=\(config.server.host) port=\(config.server.port) maxConns=\(config.server.maxConnections) rateLimit=\(config.server.rateLimit) insecure=\(config.server.insecure) tls=\(config.tls?.certPath != nil) merkle=\(config.audit.merkleEnabled) s3Bucket=\(config.audit.s3Bucket ?? "-")"
        )
        return config
    }

    // MARK: - Parsers

    private static func parseTenancyMode(_ raw: String?) throws -> TenancyMode {
        guard let raw else { return .singleTenant }
        switch raw {
        case "multi-tenant":   return .multiTenant
        case "single-tenant":  return .singleTenant
        default:
            throw ConfigParseError.invalidValue(
                name: "SPOOKTACULAR_TENANCY_MODE",
                raw: raw,
                expected: "single-tenant | multi-tenant"
            )
        }
    }

    private static func parseUInt16(_ raw: String?, name: String, default fallback: UInt16) throws -> UInt16 {
        guard let raw, !raw.isEmpty else { return fallback }
        guard let parsed = UInt16(raw) else {
            throw ConfigParseError.invalidValue(name: name, raw: raw, expected: "UInt16 0...65535")
        }
        return parsed
    }

    private static func parseInt(_ raw: String?, name: String, default fallback: Int) throws -> Int {
        guard let raw, !raw.isEmpty else { return fallback }
        guard let parsed = Int(raw) else {
            throw ConfigParseError.invalidValue(name: name, raw: raw, expected: "Int")
        }
        return parsed
    }

    private static func parseOptionalInt(_ raw: String?, name: String) throws -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let parsed = Int(raw) else {
            throw ConfigParseError.invalidValue(name: name, raw: raw, expected: "Int")
        }
        return parsed
    }

    /// Parses `Header1: val1; Header2: val2` — the env-var shape
    /// for webhook extra headers. Silently ignores malformed
    /// entries.
    private static func parseHeaders(_ raw: String) -> [String: String] {
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

    /// Loads configuration from a JSON file.
    public static func load(from path: String) throws -> SpooktacularConfig {
        let data = try Data(contentsOf: URL(filePath: path))
        return try JSONDecoder().decode(SpooktacularConfig.self, from: data)
    }
}

/// Errors raised by ``SpooktacularConfig/fromEnvironment()`` when an
/// environment variable holds a value that cannot be parsed into the
/// expected Swift type. Previously, unknown enum values or
/// non-numeric integer strings silently collapsed to defaults; that
/// behavior hid deployment misconfiguration until long after startup.
public enum ConfigParseError: Error, Sendable, Equatable, LocalizedError {

    /// An environment variable contained a value that does not
    /// match the expected shape.
    ///
    /// - Parameters:
    ///   - name: The environment variable name.
    ///   - raw: The literal value that was rejected.
    ///   - expected: Human-readable description of accepted forms.
    case invalidValue(name: String, raw: String, expected: String)

    public var errorDescription: String? {
        switch self {
        case .invalidValue(let name, let raw, let expected):
            "Environment variable \(name)='\(raw)' is not a valid \(expected)."
        }
    }

    public var recoverySuggestion: String? {
        "Fix the environment variable value or unset it to fall back to the default. "
        + "See SPOOKTACULAR_CONFIG.md for the allowed set of values."
    }
}

// MARK: - Sub-Configurations

/// A registered tenant with its host pool assignment and quotas.
public struct TenantDefinition: Sendable, Codable {
    public let id: String
    public let name: String
    public let hostPools: [String]
    public let breakGlassAllowed: Bool
    public let quota: TenantQuota?

    public init(id: String, name: String, hostPools: [String] = [],
                breakGlassAllowed: Bool = false, quota: TenantQuota? = nil) {
        self.id = id
        self.name = name
        self.hostPools = hostPools
        self.breakGlassAllowed = breakGlassAllowed
        self.quota = quota
    }
}

/// Identity provider configuration (OIDC or SAML).
public struct IdentityProviderConfig: Sendable, Codable {
    public let type: String // "oidc" or "saml"
    public let issuer: String
    public let clientID: String?
    public let certificate: String?
    public let ssoURL: String?
    public let groupRoleMapping: [String: [String]]

    public init(type: String, issuer: String, clientID: String? = nil,
                certificate: String? = nil, ssoURL: String? = nil,
                groupRoleMapping: [String: [String]] = [:]) {
        self.type = type
        self.issuer = issuer
        self.clientID = clientID
        self.certificate = certificate
        self.ssoURL = ssoURL
        self.groupRoleMapping = groupRoleMapping
    }
}

/// RBAC configuration.
public struct RBACConfig: Sendable, Codable {
    public let configPath: String?
    public let macOSGroupMapping: [String: String]?

    public init(configPath: String? = nil, macOSGroupMapping: [String: String]? = nil) {
        self.configPath = configPath
        self.macOSGroupMapping = macOSGroupMapping
    }
}

/// TLS configuration.
public struct TLSConfig: Sendable, Codable {
    public let certPath: String?
    public let keyPath: String?
    public let caPath: String?

    public init(certPath: String? = nil, keyPath: String? = nil, caPath: String? = nil) {
        self.certPath = certPath
        self.keyPath = keyPath
        self.caPath = caPath
    }
}

/// Audit logging configuration.
public struct AuditConfig: Sendable, Codable {
    public let filePath: String?
    public let immutablePath: String?
    public let merkleEnabled: Bool

    /// Keychain label for the SEP-bound P-256 signing key used by
    /// `MerkleAuditSink` to sign tree heads.
    ///
    /// SEP-bound Keychain label for the Merkle signing key.
    ///
    /// The key is generated inside the Secure Enclave on first
    /// use and stored under this label; subsequent runs
    /// reconstruct the signer from the persisted SEP blob
    /// without ever seeing the private bytes.
    ///
    /// Populated by `SPOOKTACULAR_AUDIT_SIGNING_KEY_LABEL`. Required
    /// when `merkleEnabled` is true — the legacy
    /// `SPOOKTACULAR_AUDIT_SIGNING_KEY_PATH` software-key path has been
    /// removed (see docs/THREAT_MODEL.md).
    public let merkleSigningKeyLabel: String?

    public let s3Bucket: String?
    public let s3Region: String?

    /// S3 key prefix for audit objects. Defaults to `"audit/"` so
    /// operators can drop the bucket next to unrelated objects
    /// without polluting the root.
    public let s3Prefix: String?

    /// Object Lock retention in days. Defaults to 2555 (7 years) to
    /// meet the common SOC 2 / HIPAA retention minimum.
    public let s3RetentionDays: Int?

    /// How many records to buffer before uploading a batch. Larger
    /// batches cut S3 request cost; smaller batches reduce the tail
    /// of records lost on crash. Defaults to 100.
    public let s3BatchSize: Int?

    /// SIEM webhook URL for live audit forwarding (Splunk HEC,
    /// Datadog Logs, CloudWatch, or any HTTPS ingest). When set,
    /// records are teed to the webhook alongside the primary
    /// (local JSONL) sink so SIEM outages never cause audit
    /// loss — the primary remains authoritative.
    public let webhookURL: String?

    /// Hex-encoded HMAC-SHA256 key for signing webhook request
    /// bodies. Shared with the SIEM out-of-band. When nil, no
    /// signature header is emitted.
    public let webhookHMACKeyHex: String?

    /// Extra headers to attach to every webhook request. Typical
    /// values: `Authorization: Splunk <token>`, `DD-API-KEY: ...`.
    public let webhookExtraHeaders: [String: String]?

    public init(filePath: String? = nil, immutablePath: String? = nil,
                merkleEnabled: Bool = false,
                merkleSigningKeyLabel: String? = nil,
                s3Bucket: String? = nil,
                s3Region: String? = nil,
                s3Prefix: String? = nil,
                s3RetentionDays: Int? = nil,
                s3BatchSize: Int? = nil,
                webhookURL: String? = nil,
                webhookHMACKeyHex: String? = nil,
                webhookExtraHeaders: [String: String]? = nil) {
        self.filePath = filePath
        self.immutablePath = immutablePath
        self.merkleEnabled = merkleEnabled
        self.merkleSigningKeyLabel = merkleSigningKeyLabel
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
        self.s3Prefix = s3Prefix
        self.s3RetentionDays = s3RetentionDays
        self.s3BatchSize = s3BatchSize
        self.webhookURL = webhookURL
        self.webhookHMACKeyHex = webhookHMACKeyHex
        self.webhookExtraHeaders = webhookExtraHeaders
    }
}

/// API server configuration.
public struct ServerConfig: Sendable, Codable {
    public let host: String
    public let port: UInt16
    public let maxConnections: Int
    public let rateLimit: Int
    public let insecure: Bool

    public init(host: String = "127.0.0.1", port: UInt16 = 8484,
                maxConnections: Int = 50, rateLimit: Int = 120,
                insecure: Bool = false) {
        self.host = host
        self.port = port
        self.maxConnections = maxConnections
        self.rateLimit = rateLimit
        self.insecure = insecure
    }
}
