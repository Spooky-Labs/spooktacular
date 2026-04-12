import ArgumentParser
import Foundation
import SpooktacularKit

/// CLI-local alias for ``SpooktacularPaths``.
///
/// Delegates all path logic to the shared ``SpooktacularPaths``
/// in `SpooktacularKit` so the CLI and GUI resolve paths
/// identically. Also provides the ``requireBundle(for:)`` helper
/// that prints styled error messages before throwing.
enum Paths {

    /// The root data directory: `~/.spooktacular/`.
    static var root: URL { SpooktacularPaths.root }

    /// The VM bundles directory: `~/.spooktacular/vms/`.
    static var vms: URL { SpooktacularPaths.vms }

    /// The IPSW cache directory: `~/.spooktacular/cache/ipsw/`.
    static var ipswCache: URL { SpooktacularPaths.ipswCache }

    /// Resolves a VM name to its bundle URL.
    static func bundleURL(for name: String) -> URL {
        SpooktacularPaths.bundleURL(for: name)
    }

    /// Ensures the standard directories exist.
    static func ensureDirectories() throws {
        try SpooktacularPaths.ensureDirectories()
    }

    /// Returns the bundle URL for the given VM name, printing a
    /// styled error and throwing `ExitCode.failure` if the bundle
    /// does not exist.
    ///
    /// This replaces the repeated guard-FileManager pattern across
    /// all CLI commands.
    ///
    /// - Parameter name: The VM name.
    /// - Returns: The bundle URL.
    /// - Throws: `ExitCode.failure` if the bundle does not exist.
    static func requireBundle(for name: String) throws -> URL {
        let url = bundleURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print(Style.error("✗ VM '\(name)' not found."))
            print(Style.dim("  Run 'spook list' to see available virtual machines."))
            throw ExitCode.failure
        }
        return url
    }
}
