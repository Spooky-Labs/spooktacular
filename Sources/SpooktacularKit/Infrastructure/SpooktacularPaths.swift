import Foundation

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

    /// Resolves a VM name to its bundle URL.
    ///
    /// - Parameter name: The VM name (without `.vm` extension).
    /// - Returns: The URL to `~/.spooktacular/vms/<name>.vm`.
    public static func bundleURL(for name: String) -> URL {
        vms.appendingPathComponent("\(name).vm")
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
        let url = bundleURL(for: name)
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

    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let name):
            "VM '\(name)' not found."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .vmNotFound:
            "Run 'spook list' to see available virtual machines."
        }
    }
}
