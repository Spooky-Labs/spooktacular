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

    /// Loads configuration from environment variables (backward compatible).
    public static func fromEnvironment() -> SpooktacularConfig {
        let env = ProcessInfo.processInfo.environment
        return SpooktacularConfig(
            tenancyMode: env["SPOOK_TENANCY_MODE"] == "multi-tenant" ? .multiTenant : .singleTenant,
            rbac: RBACConfig(configPath: env["SPOOK_RBAC_CONFIG"]),
            tls: TLSConfig(
                certPath: env["TLS_CERT_PATH"],
                keyPath: env["TLS_KEY_PATH"],
                caPath: env["TLS_CA_PATH"]
            ),
            audit: AuditConfig(
                filePath: env["SPOOK_AUDIT_FILE"],
                immutablePath: env["SPOOK_AUDIT_IMMUTABLE_PATH"],
                merkleEnabled: env["SPOOK_AUDIT_MERKLE"] == "1",
                s3Bucket: env["SPOOK_AUDIT_S3_BUCKET"],
                s3Region: env["SPOOK_AUDIT_S3_REGION"]
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

    /// Loads configuration from a JSON file.
    public static func load(from path: String) throws -> SpooktacularConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
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
    public let s3Bucket: String?
    public let s3Region: String?

    public init(filePath: String? = nil, immutablePath: String? = nil,
                merkleEnabled: Bool = false, s3Bucket: String? = nil,
                s3Region: String? = nil) {
        self.filePath = filePath
        self.immutablePath = immutablePath
        self.merkleEnabled = merkleEnabled
        self.s3Bucket = s3Bucket
        self.s3Region = s3Region
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
