import Foundation
import SpookCore
import SpookApplication

/// Standard directory paths for Spooktacular data.
///
/// Centralizes all path logic so both the CLI (`spook`) and the
/// GUI app (`Spooktacular`) resolve bundle locations identically.
/// ``AppState`` and CLI commands should use these paths instead
/// of constructing their own.
///
/// ## Directory Layout
///
/// ```
/// ~/.spooktacular/
/// ├── vms/               # VM bundles (<name>.vm/)
/// ├── cache/ipsw/        # Downloaded IPSW restore images
/// └── images/            # OCI and IPSW image library
/// ```
public enum SpooktacularPaths {

    /// The root data directory: `~/.spooktacular/`.
    public static let root: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".spooktacular")
    }()

    /// The VM bundles directory: `~/.spooktacular/vms/`.
    public static let vms: URL = {
        root.appendingPathComponent("vms")
    }()

    /// The IPSW cache directory: `~/.spooktacular/cache/ipsw/`.
    public static let ipswCache: URL = {
        root.appendingPathComponent("cache")
            .appendingPathComponent("ipsw")
    }()

    /// Regex for valid VM names.
    ///
    /// Matches the pattern used by the HTTP API
    /// (`HTTPAPIServer.vmNamePattern`): alphanumeric start, then up
    /// to 62 more alphanumeric / dot / underscore / hyphen
    /// characters. Centralizing the pattern here means the CLI, API,
    /// and controller all accept the same set of names — an
    /// attacker cannot sneak `../../etc/passwd` past the CLI even
    /// if the API would reject it.
    public nonisolated(unsafe) static let vmNamePattern = /^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$/

    /// Validates a VM name against ``vmNamePattern``.
    ///
    /// - Throws: ``SpooktacularPathError/invalidVMName`` if the name
    ///   contains anything other than ASCII alphanumerics, `.`, `_`,
    ///   or `-`, or if it is empty / too long.
    public static func validateVMName(_ name: String) throws {
        guard name.wholeMatch(of: vmNamePattern) != nil else {
            throw SpooktacularPathError.invalidVMName(name)
        }
    }

    /// Resolves a VM name to its bundle URL.
    ///
    /// Validates against ``vmNamePattern`` before constructing the
    /// URL. Without this check, a caller (typically from the CLI)
    /// could pass `"../../etc/passwd"` and `appendingPathComponent`
    /// would resolve outside the `vms` directory. The HTTP API
    /// validates at the router; centralizing here means CLI and
    /// SDK consumers get the same protection.
    ///
    /// - Parameter name: The VM name (without `.vm` extension).
    /// - Returns: The URL to `~/.spooktacular/vms/<name>.vm`.
    /// - Throws: ``SpooktacularPathError/invalidVMName`` when the
    ///   name contains path-traversal or shell-metacharacter
    ///   sequences.
    public static func bundleURL(for name: String) throws -> URL {
        try validateVMName(name)
        return vms.appendingPathComponent("\(name).vm")
    }

    /// Ensures the standard directories exist, creating them if
    /// necessary.
    ///
    /// - Throws: A `FileManager` error if directory creation fails.
    public static func ensureDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: vms, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ipswCache, withIntermediateDirectories: true)
    }

    /// Returns the bundle URL for the given VM name, throwing if
    /// the bundle does not exist on disk.
    ///
    /// Use this in CLI commands to replace the repeated
    /// `guard FileManager.default.fileExists` pattern.
    ///
    /// - Parameter name: The VM name.
    /// - Returns: The bundle URL.
    /// - Throws: `SpooktacularPathError.vmNotFound` if the bundle
    ///   does not exist.
    public static func requireBundle(for name: String) throws -> URL {
        let url = try bundleURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpooktacularPathError.vmNotFound(name: name)
        }
        return url
    }
}

/// Errors thrown by ``SpooktacularPaths``.
public enum SpooktacularPathError: Error, Sendable, LocalizedError {

    /// The specified VM bundle does not exist.
    case vmNotFound(name: String)

    /// The VM name contains characters that could escape the
    /// `~/.spooktacular/vms/` directory (path traversal) or
    /// confuse downstream parsers (shell metacharacters).
    case invalidVMName(String)

    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let name):
            "VM '\(name)' not found."
        case .invalidVMName(let name):
            "'\(name)' is not a valid VM name. Use 1–63 characters: letters, digits, dot, underscore, hyphen; must start with a letter or digit."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .vmNotFound:
            "Run 'spook list' to see available virtual machines."
        case .invalidVMName:
            "Rename the VM to match [a-zA-Z0-9][a-zA-Z0-9._-]{0,62}."
        }
    }
}
