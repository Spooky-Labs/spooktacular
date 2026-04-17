import Foundation
import SpookCore

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

    /// Loads configuration from environment variables.
    ///
    /// Canonical names are `SPOOK_`-prefixed. Historical un-prefixed
    /// aliases (`TLS_CERT_PATH`, `TLS_KEY_PATH`, `TLS_CA_PATH`) are
    /// accepted as a fallback so existing deployments don't break,
    /// but the prefixed form wins when both are set. A future
    /// release may drop the un-prefixed aliases; today's operators
    /// should migrate to `SPOOK_TLS_*_PATH`.
    public static func fromEnvironment() -> SpooktacularConfig {
        let env = ProcessInfo.processInfo.environment
        // `SPOOK_` wins, fall back to legacy un-prefixed name.
        func tlsPath(_ prefixed: String, _ legacy: String) -> String? {
            env[prefixed] ?? env[legacy]
        }
        return SpooktacularConfig(
            tenancyMode: env["SPOOK_TENANCY_MODE"] == "multi-tenant" ? .multiTenant : .singleTenant,
            rbac: RBACConfig(configPath: env["SPOOK_RBAC_CONFIG"]),
            tls: TLSConfig(
                certPath: tlsPath("SPOOK_TLS_CERT_PATH", "TLS_CERT_PATH"),
                keyPath:  tlsPath("SPOOK_TLS_KEY_PATH",  "TLS_KEY_PATH"),
                caPath:   tlsPath("SPOOK_TLS_CA_PATH",   "TLS_CA_PATH")
            ),
            audit: AuditConfig(
                filePath: env["SPOOK_AUDIT_FILE"],
                immutablePath: env["SPOOK_AUDIT_IMMUTABLE_PATH"],
                merkleEnabled: env["SPOOK_AUDIT_MERKLE"] == "1",
                merkleSigningKeyLabel: env["SPOOK_AUDIT_SIGNING_KEY_LABEL"],
                merkleSigningKeyPath: env["SPOOK_AUDIT_SIGNING_KEY_PATH"],
                s3Bucket: env["SPOOK_AUDIT_S3_BUCKET"],
                s3Region: env["SPOOK_AUDIT_S3_REGION"],
                s3Prefix: env["SPOOK_AUDIT_S3_PREFIX"],
                // `SPOOK_AUDIT_S3_RETENTION_DAYS` is the canonical
                // name; the hardening doc previously mentioned
                // `SPOOK_AUDIT_S3_LOCK_DAYS` — accept both so docs
                // and code stay in sync during the transition.
                s3RetentionDays: (env["SPOOK_AUDIT_S3_RETENTION_DAYS"] ?? env["SPOOK_AUDIT_S3_LOCK_DAYS"])
                    .flatMap(Int.init),
                s3BatchSize: env["SPOOK_AUDIT_S3_BATCH_SIZE"].flatMap(Int.init),
                webhookURL: env["SPOOK_AUDIT_WEBHOOK_URL"],
                webhookHMACKeyHex: env["SPOOK_AUDIT_WEBHOOK_HMAC_KEY_HEX"],
                webhookExtraHeaders: env["SPOOK_AUDIT_WEBHOOK_HEADERS"].flatMap(parseHeaders)
            ),
            server: ServerConfig(
                host: env["SPOOK_HOST"] ?? "127.0.0.1",
                port: UInt16(env["SPOOK_PORT"] ?? "") ?? 8484,
                maxConnections: Int(env["SPOOK_MAX_CONNECTIONS"] ?? "") ?? 50,
                rateLimit: Int(env["SPOOK_RATE_LIMIT"] ?? "") ?? 120,
                insecure: env["SPOOK_INSECURE_CONTROLLER"] == "1"
            )
        )
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
    /// Production default. The key is generated inside the Secure
    /// Enclave on first use and stored under this label; subsequent
    /// runs reconstruct the signer from the persisted SEP blob
    /// without ever seeing the private bytes.
    ///
    /// Populated by `SPOOK_AUDIT_SIGNING_KEY_LABEL`. Mutually
    /// exclusive with `merkleSigningKeyPath`.
    public let merkleSigningKeyLabel: String?

    /// Path to a PEM-encoded P-256 software signing key.
    ///
    /// Fallback for CI, unit tests, and hosts without a Secure
    /// Enclave. Populated by `SPOOK_AUDIT_SIGNING_KEY_PATH`.
    /// Mutually exclusive with `merkleSigningKeyLabel`.
    ///
    /// When `merkleEnabled` is true and neither this nor
    /// `merkleSigningKeyLabel` is set, the factory refuses to
    /// build a Merkle sink so operators don't silently get
    /// ephemeral keys.
    public let merkleSigningKeyPath: String?

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
                merkleSigningKeyPath: String? = nil,
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
        self.merkleSigningKeyPath = merkleSigningKeyPath
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
