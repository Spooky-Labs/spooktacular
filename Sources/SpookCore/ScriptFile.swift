import Foundation

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
    /// Intended to be called from a `defer` immediately after the
    /// VM consumes the script. Silent on failure: a missing dir
    /// (already cleaned, never existed, removed by another
    /// process) is not an error — we're best-effort, not an
    /// audit surface.
    ///
    /// The host-side window the script lives on disk shrinks from
    /// "process lifetime" to "provisioning run duration" — which,
    /// combined with the 1-hour single-use TTL on GitHub
    /// registration tokens, makes exfiltration-after-the-fact
    /// worthless.
    public static func cleanup(scriptURL: URL) {
        let dir = scriptURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: dir)
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
