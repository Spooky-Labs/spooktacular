import Foundation
import SpooktacularCore

/// Generates the first-boot script that installs
/// `spooktacular-agent` inside a fresh macOS guest.
///
/// This runs before Setup Assistant (no user account exists
/// yet), so SSH and the guest-agent RPC are both unavailable —
/// the only reliable install path is `DiskInjector`: mount the
/// APFS data volume pre-boot, drop a LaunchDaemon, and have
/// `launchd` run the script at first boot as root.
///
/// ## What the generated script does
///
/// 1. Decodes a base64-embedded `spooktacular-agent` binary
///    onto `/usr/local/bin/spooktacular-agent` (mode `0755`).
/// 2. Invokes `spooktacular-agent --install-daemon` so the
///    agent registers its own LaunchDaemon at
///    `/Library/LaunchDaemons/com.spooktacular.agent.plist`.
/// 3. `launchctl bootstrap`s that daemon so the agent starts
///    immediately — the caller doesn't have to wait for a
///    reboot before the host listener sees its first frame.
/// 4. Exits 0. Any user-provided template script the caller
///    wants to run afterwards can be concatenated onto the
///    returned content.
///
/// ## Embed size
///
/// The agent binary is ~8–10 MB; base64 inflates that to
/// ~12–14 MB of script text. Disk-injection writes that to a
/// plain file on the guest's data volume — well under any
/// practical size concern, and the script self-deletes the
/// embedded blob after decode. The bash heredoc handles the
/// data without shell-escaping because `base64` output is
/// strictly alphanumeric + `+/=`.
///
/// ## Why not download over the network?
///
/// First boot often has no network (Setup Assistant locks
/// connectivity until the user configures Wi-Fi), and even
/// when it does, a network-fetched binary means trust on the
/// guest side — the host would have to pin a public key or
/// CA certificate. Embedding sidesteps both problems.
public enum AgentBootstrapTemplate {

    /// Reads the agent binary from `agentBinaryURL` and
    /// returns a generated bash script that installs + starts
    /// it at first boot.
    ///
    /// The returned `URL` points at a file in
    /// `~/Library/Caches/com.spooktacular/` — the same cache
    /// directory the other templates write to, so the existing
    /// `ScriptFile.cleanup(scriptURL:)` handles deletion after
    /// injection.
    ///
    /// - Parameters:
    ///   - agentBinaryURL: Location of the `spooktacular-agent`
    ///     Mach-O to embed. `build-app.sh` bundles the binary
    ///     at `Contents/MacOS/spooktacular-agent`; callers use
    ///     ``locateAgentBinary()`` to resolve that path.
    ///   - userScript: Optional extra bash the caller wants
    ///     appended — the GitHub-runner / OpenClaw / remote-
    ///     desktop templates currently disk-inject a standalone
    ///     script; combining them into the same first-boot run
    ///     means we install the agent AND the user's workload
    ///     in one LaunchDaemon invocation. `nil` skips.
    /// - Returns: A file URL in the shared script cache.
    /// - Throws: `CocoaError` if reading the binary or writing
    ///   the script fails.
    public static func generate(
        agentBinaryURL: URL,
        appending userScript: String? = nil
    ) throws -> URL {
        let data = try Data(contentsOf: agentBinaryURL)
        let encoded = data.base64EncodedString()
        let trailer: String
        if let userScript, !userScript.isEmpty {
            trailer = """

            # ──────────────────────────────────────────────
            # User-supplied provisioning (template or custom).
            # ──────────────────────────────────────────────
            \(userScript)
            """
        } else {
            trailer = ""
        }

        let content = """
        #!/bin/bash
        set -euo pipefail

        # ──────────────────────────────────────────────
        # Install spooktacular-agent from embedded binary.
        # Runs as root (LaunchDaemon) on first boot, before
        # Setup Assistant — no network, no user account, no
        # SSH required.
        # ──────────────────────────────────────────────
        TARGET=/usr/local/bin/spooktacular-agent
        TMPBIN=$(mktemp)
        base64 -D -o "$TMPBIN" <<'SPOOK_AGENT_BASE64_EOF'
        \(encoded)
        SPOOK_AGENT_BASE64_EOF

        mkdir -p "$(dirname "$TARGET")"
        mv "$TMPBIN" "$TARGET"
        chmod 0755 "$TARGET"

        # `--install-daemon` writes the LaunchDaemon plist at
        # /Library/LaunchDaemons/com.spooktacular.agent.plist
        # and `launchctl bootstrap system` loads it immediately.
        # Both steps are idempotent — re-running is a no-op.
        "$TARGET" --install-daemon
        \(trailer)
        """
        return try ScriptFile.writeToCache(
            script: content,
            fileName: "install-agent-bootstrap.sh"
        )
    }

    /// Resolves the bundled `spooktacular-agent` binary.
    ///
    /// Discovery order:
    ///
    /// 1. `$SPOOKTACULAR_AGENT_BINARY` environment override —
    ///    for tests and advanced operators who want to ship a
    ///    custom-built agent.
    /// 2. Sibling of the currently-running executable —
    ///    `Contents/MacOS/spooktacular-agent` when the GUI runs
    ///    out of `Spooktacular.app`, or `.build/debug/…` when a
    ///    developer runs from `swift run`.
    /// 3. `PATH` lookup via `which spooktacular-agent` as a
    ///    last resort.
    ///
    /// Returns `nil` if none resolve — callers treat that as
    /// "skip the bootstrap, user will install manually via
    /// `spook remote install-agent`".
    public static func locateAgentBinary() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["SPOOKTACULAR_AGENT_BINARY"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        let sibling = executable
            .deletingLastPathComponent()
            .appendingPathComponent("spooktacular-agent")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        // `which` fallback. Returns an empty string if not
        // found, which `isExecutableFile` rejects.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["spooktacular-agent"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
