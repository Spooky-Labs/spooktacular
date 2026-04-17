import Foundation

/// An error raised by ``ScriptFile/cleanup(scriptURL:log:)`` when
/// the backing directory could not be removed.
///
/// Callers that prefer best-effort semantics may swallow this error
/// (e.g. within a `defer`), but the method no longer swallows it on
/// their behalf: a bundle-protection or permission error that leaves
/// a registration-token script on disk is exactly the kind of silent
/// failure the codebase is auditing away.
public enum ScriptFileError: Error, Sendable, Equatable, LocalizedError {

    /// Removal of the per-invocation cache directory failed.
    ///
    /// - Parameters:
    ///   - path: The absolute path that could not be removed.
    ///   - description: The underlying `FileManager` error description.
    case cleanupFailed(path: String, description: String)

    public var errorDescription: String? {
        switch self {
        case .cleanupFailed(let path, let description):
            "Failed to remove script cache directory '\(path)': \(description)."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cleanupFailed:
            "Verify the process owner has write permission to the cache "
            + "directory. The script may still be on disk and should be "
            + "removed manually to avoid leaving registration tokens around."
        }
    }
}

/// Writes executable shell scripts to per-user cache directories
/// with owner-only permissions.
///
/// Used by template types (``GitHubRunnerTemplate``,
/// ``RemoteDesktopTemplate``, ``OpenClawTemplate``) to stage
/// provisioning scripts that may embed secrets — GitHub runner
/// registration tokens, remote-desktop credentials, API keys
/// injected via user-data. The VM consumes the script once; any
/// other local user on the host must not be able to read it.
///
/// ## Threat model
///
/// An earlier version wrote to `/tmp/spooktacular-<uuid>/` with
/// directory mode 0755 and file mode 0755 — world-readable. A
/// local non-privileged user on a shared Mac could enumerate the
/// temp tree and harvest the embedded registration token before
/// the VM consumed it. GitHub registration tokens are short-lived
/// (1 hour, single-use) but the window is enough for an on-host
/// attacker to race the registration and substitute their own
/// runner, injecting a foothold into the CI fleet.
///
/// The fix: write the script under the owner's home cache
/// directory (`~/Library/Caches/com.spooktacular/provisioning/`)
/// with directory mode 0700 and file mode 0700. The owner bit
/// preserves script execution; group/world bits are stripped.
///
/// Callers must delete the script after the VM has consumed it;
/// retention is a caller concern, not ours.
public enum ScriptFile {

    /// Deletes the per-invocation cache directory that held a
    /// script written via ``writeToCache(script:fileName:)``.
    ///
    /// The cache layout is
    /// `~/Library/Caches/com.spooktacular/provisioning/<uuid>/<filename>`
    /// — this helper removes the `<uuid>/` container so the
    /// script bytes, their enclosing directory, and any sibling
    /// files the caller wrote alongside them are all unlinked in
    /// one call.
    ///
    /// A missing directory (already cleaned, never existed) is NOT
    /// an error: that's the expected steady-state result of being
    /// called twice. Any other failure — permission denied, volume
    /// disappeared, I/O error — throws ``ScriptFileError/cleanupFailed(path:description:)``
    /// so the caller can log, increment a metric, or surface in an
    /// audit record. A silent `try?` would leave a registration
    /// token on disk indefinitely; the defensive contract here is
    /// "if cleanup didn't happen, the caller is told."
    ///
    /// Intended to be called from a `defer` immediately after the
    /// VM consumes the script. Callers that truly want best-effort
    /// may catch and discard the error themselves — the decision
    /// lives with the caller, not the implementation.
    ///
    /// The host-side window the script lives on disk shrinks from
    /// "process lifetime" to "provisioning run duration" — which,
    /// combined with the 1-hour single-use TTL on GitHub
    /// registration tokens, makes exfiltration-after-the-fact
    /// worthless.
    ///
    /// - Parameters:
    ///   - scriptURL: The URL returned by ``writeToCache(script:fileName:)``.
    ///   - log: A ``LogProvider`` that captures error-level entries.
    ///     Defaults to ``SilentLogProvider`` for callers that are
    ///     fine with just the thrown error.
    /// - Throws: ``ScriptFileError/cleanupFailed(path:description:)``
    ///   when the directory exists but cannot be removed.
    public static func cleanup(
        scriptURL: URL,
        log: any LogProvider = SilentLogProvider()
    ) throws {
        let fm = FileManager.default
        let dir = scriptURL.deletingLastPathComponent()
        // Idempotent no-op: nothing was written (e.g. the caller
        // aborted before `writeToCache`) or cleanup already ran.
        // We key on `scriptURL` — not the containing dir — because
        // the dir may be a shared root (e.g. `/tmp`) whose
        // existence says nothing about whether we own anything in
        // it.
        guard fm.fileExists(atPath: scriptURL.path) else { return }
        do {
            try fm.removeItem(at: dir)
        } catch {
            log.error(
                "ScriptFile cleanup failed for \(dir.path): \(error.localizedDescription)"
            )
            throw ScriptFileError.cleanupFailed(
                path: dir.path,
                description: error.localizedDescription
            )
        }
    }

    /// Writes a shell script to a per-user cache directory with
    /// owner-only permissions (mode 0700 on both directory and
    /// file).
    public static func writeToCache(
        script: String,
        fileName: String
    ) throws -> URL {
        let fm = FileManager.default
        let cacheRoot = try fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let scriptRoot = cacheRoot
            .appendingPathComponent("com.spooktacular")
            .appendingPathComponent("provisioning")
            .appendingPathComponent(UUID().uuidString)

        try fm.createDirectory(
            at: scriptRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // `createDirectory` only applies the permissions to the
        // leaf when `withIntermediateDirectories: true`. Tighten
        // the final dir explicitly so an adversary can't
        // enumerate the sibling UUIDs of concurrent provisionings.
        try fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptRoot.path
        )

        let scriptURL = scriptRoot.appendingPathComponent(fileName)
        try Data(script.utf8).write(to: scriptURL, options: [.atomic])

        // Owner-only executable. The `x` bit lets the VM run the
        // script; removing group/world bits prevents any other
        // local user from reading the embedded secret.
        try fm.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: scriptURL.path
        )

        return scriptURL
    }

}
