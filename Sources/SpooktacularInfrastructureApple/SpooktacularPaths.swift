import Foundation
import SpooktacularCore
import SpooktacularApplication

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

    /// The per-VM host-API socket directory:
    /// `~/Library/Application Support/Spooktacular/api/`.
    ///
    /// Lives under `Application Support` (not the dot-prefixed
    /// `~/.spooktacular/`) because it's ephemeral runtime state
    /// — a socket file survives only while the VM runs, and the
    /// directory itself is mode-0700 so only the current user
    /// can connect. Both follow macOS HIG conventions: user-
    /// scoped runtime data goes in Application Support, not the
    /// home root.
    ///
    /// The streaming API server (``VMStreamingServer``) creates
    /// the directory on first bind with `0700` and a per-VM
    /// `.sock` file on `start()` that's unlinked on `stop()`.
    public static let apiSockets: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Spooktacular")
        .appendingPathComponent("api")
    }()

    /// Returns the socket path for `name`'s host-API listener.
    ///
    /// - Throws: ``VirtualMachineBundleError`` mirroring the
    ///   same-error shape used by ``bundleURL(for:)`` if the
    ///   name contains path-traversal characters.
    public static func apiSocketURL(for name: String) throws -> URL {
        try validateVMName(name)
        return apiSockets.appendingPathComponent("\(name).sock")
    }

    /// Default RBAC config path: `~/.spooktacular/rbac.json`.
    ///
    /// Used as the fallback when `SPOOKTACULAR_RBAC_CONFIG` is unset so
    /// runtime role assignments via `/v1/roles/assign` persist
    /// across restarts without the operator having to configure
    /// anything. The previous behavior — in-memory-only when the
    /// env var was absent — silently dropped assignments on every
    /// restart, which a Fortune-20 auditor correctly flagged as
    /// unsafe. Operators who genuinely want in-memory-only
    /// behavior can pass `SPOOKTACULAR_RBAC_CONFIG=/dev/null`.
    public static let rbacConfig: URL = {
        root.appendingPathComponent("rbac.json")
    }()

    /// Validates a VM name.
    ///
    /// Accepts names matching the grammar
    /// `[A-Za-z0-9][A-Za-z0-9._-]{0,62}` — an alphanumeric
    /// first character followed by 0–62 more alphanumeric,
    /// `.`, `_`, or `-` characters (1–63 total).
    ///
    /// Implemented as a pure character-class check rather
    /// than via `Regex<Substring>` because:
    ///
    /// - `Regex<Substring>` isn't `Sendable` (verified via
    ///   Swift 6 compiler error: *"may have shared mutable
    ///   state"*), which would force a `nonisolated(unsafe)`
    ///   escape hatch on any static instance.
    /// - The grammar is trivial enough that the Regex
    ///   engine is strictly more machinery than the
    ///   problem requires — a single pass over the bytes
    ///   is faster and exactly as correct.
    /// - A pure function is `Sendable` by construction.
    ///
    /// The HTTP API (`HTTPAPIServer.validateVMName`) uses
    /// the same grammar; centralizing the check here means
    /// CLI, API, and controller all accept the same set of
    /// names — an attacker cannot sneak
    /// `../../etc/passwd` past the CLI even if the API
    /// would reject it.
    ///
    /// - Throws: ``SpooktacularPathError/invalidVMName`` if
    ///   the name is empty, over 63 characters, starts with
    ///   a non-alphanumeric character, or contains any
    ///   character other than ASCII alphanumerics, `.`,
    ///   `_`, or `-`.
    public static func validateVMName(_ name: String) throws {
        guard isValidVMName(name) else {
            throw SpooktacularPathError.invalidVMName(name)
        }
    }

    /// Pure predicate backing ``validateVMName(_:)`` —
    /// exposed for callers that need a Bool without the
    /// throwing branch.
    public static func isValidVMName(_ name: String) -> Bool {
        // 1–63 character bound.
        guard (1...63).contains(name.count) else { return false }

        // `String.utf8` iterates the UTF-8 bytes without
        // decoding graphemes; fine here because the grammar
        // is ASCII-only.  Any non-ASCII character fails the
        // `is*ASCII` tests below.
        var iterator = name.utf8.makeIterator()
        guard let first = iterator.next(),
              Self.isASCIIAlphanumeric(first)
        else { return false }
        while let byte = iterator.next() {
            guard Self.isASCIIAlphanumeric(byte)
                    || byte == .init(ascii: ".")
                    || byte == .init(ascii: "_")
                    || byte == .init(ascii: "-")
            else { return false }
        }
        return true
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= .init(ascii: "0") && byte <= .init(ascii: "9"))
            || (byte >= .init(ascii: "A") && byte <= .init(ascii: "Z"))
            || (byte >= .init(ascii: "a") && byte <= .init(ascii: "z"))
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
