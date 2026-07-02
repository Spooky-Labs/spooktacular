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
        tls: TLSConfig? = nil,
        audit: AuditConfig = .init(),
        server: ServerConfig = .init()
    ) {
        self.tenancyMode = tenancyMode
        self.tenants = tenants
        self.rbac = rbac
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
                immutablePath: env["SPOOKTACULAR_AUDIT_IMMUTABLE_PATH"]
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
            "config resolved tenancy=\(config.tenancyMode.rawValue) host=\(config.server.host) port=\(config.server.port) maxConns=\(config.server.maxConnections) rateLimit=\(config.server.rateLimit) insecure=\(config.server.insecure) tls=\(config.tls?.certPath != nil)"
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

    public init(filePath: String? = nil, immutablePath: String? = nil) {
        self.filePath = filePath
        self.immutablePath = immutablePath
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
