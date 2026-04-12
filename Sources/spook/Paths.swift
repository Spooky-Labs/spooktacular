import Foundation

/// Standard directory paths for Spooktacular data.
enum Paths {

    /// The root data directory: `~/.spooktacular/`.
    static let root: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".spooktacular")
    }()

    /// The VM bundles directory: `~/.spooktacular/vms/`.
    static let vms: URL = {
        root.appendingPathComponent("vms")
    }()

    /// The IPSW cache directory: `~/.spooktacular/cache/ipsw/`.
    static let ipswCache: URL = {
        root.appendingPathComponent("cache")
            .appendingPathComponent("ipsw")
    }()

    /// Resolves a VM name to its bundle URL.
    static func bundleURL(for name: String) -> URL {
        vms.appendingPathComponent("\(name).vm")
    }

    /// Ensures the standard directories exist.
    static func ensureDirectories() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: vms, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: ipswCache, withIntermediateDirectories: true)
    }
}
