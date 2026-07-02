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
/// ├── vms/               # VM bundles (<uuid>.vm/)
/// ├── cache/ipsw/        # Downloaded IPSW restore images
/// └── images/            # OCI and IPSW image library
/// ```
///
/// Bundle directories are named by the VM's stable UUID,
/// not its display name. Renaming a VM rewrites only
/// `metadata.json/displayName`; the on-disk directory never
/// moves once created.
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
    /// can connect.
    public static let apiSockets: URL = {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Spooktacular")
        .appendingPathComponent("api")
    }()

    /// Returns the socket path for a VM's host-API listener.
    ///
    /// - Parameter id: The VM's stable UUID.
    /// - Returns: `~/Library/Application Support/Spooktacular/api/<uuid>.sock`.
    public static func apiSocketURL(for id: UUID) -> URL {
        apiSockets.appendingPathComponent("\(id.uuidString).sock")
    }

    /// Default RBAC config path: `~/.spooktacular/rbac.json`.
    public static let rbacConfig: URL = {
        root.appendingPathComponent("rbac.json")
    }()

    // MARK: - Display-name validation

    /// Validates a user-facing display name.
    ///
    /// Rules (deliberately looser than the pre-UUID `validateVMName`
    /// because the name is no longer a filesystem path component):
    ///
    /// - 1–128 Unicode characters after trimming leading/trailing
    ///   whitespace.
    /// - No ASCII control characters (category `Cc`).
    /// - No forward or backward slashes (they'd confuse path
    ///   rendering in the sidebar + CLI output even though the
    ///   filesystem never sees them).
    ///
    /// Spaces, unicode letters, digits, and typical punctuation
    /// (dot, underscore, dash, parentheses, apostrophe) are all
    /// permitted — two VMs may share the same display name, so
    /// the name's job is presentation, not uniqueness.
    public static func validateDisplayName(_ name: String) throws {
        guard isValidDisplayName(name) else {
            throw SpooktacularPathError.invalidDisplayName(name)
        }
    }

    /// Pure predicate backing ``validateDisplayName(_:)``.
    public static func isValidDisplayName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(trimmed.count) else { return false }
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            if scalar == "/" || scalar == "\\" { return false }
        }
        return true
    }

    // MARK: - UUID-keyed bundle paths

    /// Returns the bundle URL for the given VM identifier.
    ///
    /// - Parameter id: The VM's stable UUID.
    /// - Returns: `~/.spooktacular/vms/<uuid>.vm`.
    public static func bundleURL(for id: UUID) -> URL {
        vms.appendingPathComponent("\(id.uuidString).vm")
    }

    /// Returns the bundle URL for the given VM identifier,
    /// throwing if the bundle does not exist on disk.
    ///
    /// - Parameter id: The VM's stable UUID.
    /// - Returns: The bundle URL.
    /// - Throws: ``SpooktacularPathError/vmNotFound(id:)`` if the
    ///   bundle does not exist.
    public static func requireBundle(for id: UUID) throws -> URL {
        let url = bundleURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SpooktacularPathError.vmNotFound(id: id)
        }
        return url
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

    // MARK: - Selector resolution (CLI + HTTP API)

    /// Resolves a user-supplied VM *selector* — either a
    /// canonical UUID string or a display name — to a
    /// concrete bundle URL on disk.
    ///
    /// Resolution order:
    ///
    /// 1. If the selector parses as a `UUID`, return the
    ///    UUID-keyed bundle path directly (fastest; no
    ///    directory scan, matches the primary-key lookup).
    /// 2. Otherwise scan `~/.spooktacular/vms/` for bundles
    ///    whose `metadata.json`'s `displayName` field matches
    ///    the selector exactly (case-sensitive).
    ///    - Zero matches → ``SpooktacularPathError/vmNotFoundBySelector(_:)``.
    ///    - Exactly one match → return its URL.
    ///    - Multiple matches → ``SpooktacularPathError/ambiguousSelector(selector:candidates:)``
    ///      carrying every matching UUID so the caller can
    ///      render a disambiguation prompt.
    ///
    /// This helper lets the CLI accept `spook start foo`
    /// (friendly) AND `spook start 4A5B…` (unambiguous) from
    /// the same argument, and lets the HTTP API accept either
    /// shape on `/v1/vms/<selector>` routes. The JSON decode
    /// is deliberately lightweight — just enough to reach the
    /// `displayName` field — so a directory with a malformed
    /// `metadata.json` doesn't crash the resolver, it's just
    /// skipped.
    ///
    /// - Parameter selector: The UUID string or display name.
    /// - Returns: The absolute URL of the resolved bundle.
    /// - Throws: ``SpooktacularPathError`` on any failure shape.
    public static func resolveBundle(selector: String) throws -> URL {
        if let id = UUID(uuidString: selector) {
            return try requireBundle(for: id)
        }
        let matches = try scanForDisplayName(selector)
        switch matches.count {
        case 0:
            throw SpooktacularPathError.vmNotFoundBySelector(selector)
        case 1:
            return matches[0].url
        default:
            throw SpooktacularPathError.ambiguousSelector(
                selector: selector,
                candidates: matches.map(\.id)
            )
        }
    }

    /// Resolves a user-supplied selector to just the VM's
    /// UUID — useful when the caller wants to key an in-memory
    /// dict, not load from disk.
    public static func resolveID(selector: String) throws -> UUID {
        if let id = UUID(uuidString: selector) {
            // Confirm the bundle actually exists; otherwise
            // callers can't distinguish "typo'd UUID" from
            // "VM exists".
            _ = try requireBundle(for: id)
            return id
        }
        let matches = try scanForDisplayName(selector)
        switch matches.count {
        case 0:
            throw SpooktacularPathError.vmNotFoundBySelector(selector)
        case 1:
            return matches[0].id
        default:
            throw SpooktacularPathError.ambiguousSelector(
                selector: selector,
                candidates: matches.map(\.id)
            )
        }
    }

    private struct DisplayNameMatch {
        let id: UUID
        let url: URL
    }

    /// Scans the VMs directory for bundles whose
    /// `metadata.json/displayName` equals `name`. Malformed
    /// bundles are skipped silently (logged elsewhere).
    private static func scanForDisplayName(_ name: String) throws -> [DisplayNameMatch] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: vms.path) else { return [] }
        let entries = try fm.contentsOfDirectory(
            at: vms,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var matches: [DisplayNameMatch] = []
        struct MinimalMetadata: Decodable {
            let id: UUID
            let displayName: String?
        }
        let decoder = JSONDecoder()
        for entry in entries where entry.pathExtension == "vm" {
            let metadataURL = entry.appendingPathComponent("metadata.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let meta = try? decoder.decode(MinimalMetadata.self, from: data)
            else { continue }
            // Pre-migration bundles without a displayName field
            // fall back to the directory basename — matches the
            // migration behaviour in `VirtualMachineBundle.load`.
            let effectiveName = meta.displayName
                ?? entry.deletingPathExtension().lastPathComponent
            if effectiveName == name {
                matches.append(DisplayNameMatch(id: meta.id, url: entry))
            }
        }
        return matches
    }
}

/// Errors thrown by ``SpooktacularPaths``.
public enum SpooktacularPathError: Error, Sendable, LocalizedError {

    /// The specified VM bundle does not exist.
    case vmNotFound(id: UUID)

    /// The user-facing display name is invalid. See
    /// ``SpooktacularPaths/isValidDisplayName(_:)`` for the rules.
    case invalidDisplayName(String)

    /// No VM matched the user-supplied selector (UUID string or
    /// display name) — reported by the CLI when the resolver
    /// can't disambiguate.
    case vmNotFoundBySelector(String)

    /// Multiple VMs matched the user-supplied selector. Carries
    /// the matching UUIDs so the CLI can print a disambiguation
    /// list.
    case ambiguousSelector(selector: String, candidates: [UUID])

    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let id):
            "VM '\(id.uuidString)' not found."
        case .invalidDisplayName(let name):
            "'\(name)' is not a valid VM display name. Use 1–128 characters after trimming; no slashes or control characters."
        case .vmNotFoundBySelector(let selector):
            "No VM named '\(selector)' or matching that UUID."
        case .ambiguousSelector(let selector, let candidates):
            "'\(selector)' matches \(candidates.count) VMs. Use the full UUID: \(candidates.map(\.uuidString).joined(separator: ", "))."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .vmNotFound:
            "Run 'spook list' to see available virtual machines."
        case .invalidDisplayName:
            "Trim whitespace and remove any slashes or control characters; display names are 1–128 characters."
        case .vmNotFoundBySelector:
            "Run 'spook list' to see available VMs, or copy the UUID from the sidebar."
        case .ambiguousSelector:
            "Copy the full UUID of the VM you meant and pass that as the selector."
        }
    }
}
