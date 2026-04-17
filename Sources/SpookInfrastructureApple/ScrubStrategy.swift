import Foundation
import SpookCore
import SpookApplication

/// The outcome of a ``ScrubStrategy/recycleWithValidation(vm:source:using:on:reusePolicy:)``
/// (or equivalent on ``SnapshotStrategy`` / ``RecloneStrategy``) call.
///
/// Callers inspect this to decide whether the VM is safe to schedule
/// new work on (``clean``) or whether it was destroyed because it
/// failed post-recycle validation (``destroyed``).
public enum RecycleResult: Sendable, Equatable {
    /// The VM passed validation and is safe to reuse.
    case clean
    /// Validation failed; the VM was stopped and deleted to prevent dirty reuse.
    case destroyed
}

/// Recycles a VM by running an in-place cleanup script inside the guest.
///
/// Fastest strategy, lowest isolation. The cleanup script kills user
/// processes, removes the runner work directory, clears the clipboard,
/// and removes temp files. If cleanup fails, throws ``RecycleError``.
///
/// ## Validation Coverage
///
/// Validation runs a **battery** of guest-agent exec checks, not just
/// a single script. Each check corresponds to a known class of runner
/// residue. All checks must pass for ``RecycleOutcome/readyForNextJob``:
///
/// | Check | Signal of | Outcome on fail |
/// |-------|-----------|-----------------|
/// | No runner processes | User code still running | `needsRetry` |
/// | `/Users/runner/work` absent | Job workspace cleanup | `needsRetry` |
/// | Clipboard empty | Credential leak via copy-paste | `needsRetry` |
/// | `/tmp`, `/var/tmp`, `~/Library/Caches` empty | Job artifacts / build caches | `needsRetry` |
/// | No `ssh-agent` running | Cached SSH key would leak | `needsRetry` |
/// | No Docker / container daemons | Containerized runner state | `needsRetry` |
/// | No non-SSH listening TCP sockets | Backdoor / reverse shell | `needsRetry` |
/// | Only known-safe LaunchAgents / LaunchDaemons | Persistence mechanism | `needsRetry` |
/// | Guest agent reachable | Structural / network failure | `failed` |
///
/// A ``RecycleOutcome/failed(reason:)`` outcome indicates the VM is
/// structurally unhealthy and cannot be retried — the caller must
/// destroy it.
public struct ScrubStrategy: RecycleStrategy {

    private let log: any LogProvider

    /// The cleanup script executed by ``recycle(vm:source:using:on:)``.
    ///
    /// Runs on the guest via the runner break-glass exec channel. Order matters:
    /// 1. Kill all runner-owned processes (including ssh-agent, docker, etc.).
    /// 2. Remove the runner workspace.
    /// 3. Clear the clipboard (pasteboard) to prevent credential carry-over.
    /// 4. Wipe `/tmp`, `/var/tmp`, `~/Library/Caches`.
    private let cleanupScript = """
        killall -u runner 2>/dev/null || true; \
        rm -rf /Users/runner/work; \
        pbcopy < /dev/null; \
        rm -rf /tmp/* /var/tmp/* /var/folders/*/*/* 2>/dev/null || true; \
        rm -rf /Users/runner/Library/Caches/* 2>/dev/null || true
        """

    /// Shell commands executed during validation.
    ///
    /// Each tuple is `(check name, command)`. A command exit code of
    /// `0` means the check passed (clean). Any non-zero exit code
    /// maps to a ``RecycleOutcome/needsRetry(reason:)`` with the check
    /// name as the reason.
    ///
    /// A separate pre-check (guest-agent reachability) runs before
    /// these — its failure produces ``RecycleOutcome/failed(reason:)``
    /// rather than `needsRetry` because no amount of scrub-retry will
    /// bring a dead guest agent back.
    private var validationChecks: [(name: String, command: String)] {
        [
            ("runner processes still running",
             "pgrep -u runner > /dev/null 2>&1 && exit 1 || exit 0"),

            ("/Users/runner/work still present",
             "[ ! -d /Users/runner/work ]"),

            ("clipboard not empty",
             "[ -z \"$(pbpaste 2>/dev/null)\" ]"),

            ("/tmp not empty",
             "[ -z \"$(ls -A /tmp 2>/dev/null)\" ]"),

            ("/var/tmp not empty",
             "[ -z \"$(ls -A /var/tmp 2>/dev/null)\" ]"),

            ("~/Library/Caches not empty",
             "[ -z \"$(ls -A /Users/runner/Library/Caches 2>/dev/null)\" ]"),

            ("ssh-agent still running",
             "pgrep -x ssh-agent > /dev/null 2>&1 && exit 1 || exit 0"),

            ("docker or container daemon still running",
             "pgrep -x -f 'com.docker|dockerd|containerd|colima|podman' > /dev/null 2>&1 && exit 1 || exit 0"),

            ("unexpected LaunchAgents or LaunchDaemons present",
             Self.unexpectedLaunchDaemonCheck()),

            ("unexpected TCP listening sockets",
             Self.unexpectedListenerCheck()),
        ]
    }

    /// Known-safe LaunchAgent / LaunchDaemon labels.
    ///
    /// A recycled VM is expected to have exactly these daemons running
    /// plus anything shipped by macOS itself (prefix `com.apple.`).
    /// Any label outside this set signals that a job installed a
    /// persistence mechanism.
    ///
    /// ## Entries
    ///
    /// - `com.spooktacular.guest-agent`: the Spooktacular guest agent
    ///   that lets the host reach the VM over vsock. Required.
    /// - `com.spooktacular.shared-folder-watcher`: the VirtIO
    ///   shared-folder watcher installed by ``SharedFolderProvisioner``.
    ///   Optional depending on provisioning mode.
    /// - `com.github.actions.runner`: the GitHub Actions runner
    ///   LaunchAgent. Present after runner registration.
    ///
    /// Adding to this list relaxes scrub validation — any new entry
    /// must be justified with a code-review comment explaining why
    /// that daemon is safe to persist across jobs.
    public static let knownSafeLaunchDaemonLabels: [String] = [
        "com.spooktacular.guest-agent",
        "com.spooktacular.shared-folder-watcher",
        "com.github.actions.runner",
    ]

    /// Known-safe listening ports.
    ///
    /// A recycled VM should have **only** these TCP listeners.
    /// Anything else (reverse shell, dev server, web hook listener)
    /// is runner residue and signals a dirty recycle.
    ///
    /// - `22`: OpenSSH. Required for `spook ssh` fallback.
    public static let knownSafeListenerPorts: [Int] = [22]

    /// Builds the shell command that fails if an unknown LaunchAgent
    /// or LaunchDaemon is loaded.
    ///
    /// Uses `launchctl list` and filters out (a) macOS-provided
    /// services (`com.apple.*`) and (b) the data-driven
    /// ``knownSafeLaunchDaemonLabels`` allowlist.
    private static func unexpectedLaunchDaemonCheck() -> String {
        // Escape each allowlist entry for egrep: dots are the only
        // regex metacharacter we expect to encounter in a reverse-DNS
        // label, and they match anything — strip them safely.
        let labels = knownSafeLaunchDaemonLabels
            .map { "^" + $0.replacingOccurrences(of: ".", with: "\\.") + "$" }
            .joined(separator: "|")

        return """
            count=$(launchctl list 2>/dev/null | awk '{print $3}' \
              | grep -v '^Label$' \
              | grep -v '^$' \
              | grep -v '^com\\.apple\\.' \
              | grep -vE '\(labels)' \
              | wc -l | tr -d ' '); \
            [ "$count" = "0" ]
            """
    }

    /// Builds the shell command that fails if an unexpected TCP port
    /// is listening.
    ///
    /// Uses `lsof -i -P -n` (on BSD/macOS) to enumerate listeners and
    /// allows only ports in ``knownSafeListenerPorts`` and the
    /// guest-agent vsock ports (which do not show up in `lsof -i`
    /// but are listed here for documentation).
    private static func unexpectedListenerCheck() -> String {
        // Allow lsof to return non-zero when nothing is listening —
        // that is the success case. We only fail if a line remains
        // after stripping the allowlist.
        let allowed = knownSafeListenerPorts
            .map { ":\($0) " }
            .joined(separator: "|")

        return """
            lines=$(lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | tail -n +2 \
              | grep -vE '\(allowed)' \
              | wc -l | tr -d ' '); \
            [ "$lines" = "0" ]
            """
    }

    /// Creates a new scrub strategy.
    ///
    /// - Parameter log: Logger for diagnostic messages.
    public init(log: any LogProvider = SilentLogProvider()) {
        self.log = log
    }

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        log.info("Recycling VM '\(vm)' via scrub")
        let result = try await node.execInGuest(vm: vm, command: cleanupScript, on: endpoint)
        guard result.exitCode == 0 else {
            log.error("Scrub failed for VM '\(vm)': exit \(result.exitCode)")
            throw RecycleError.scrubFailed(vm: vm, exitCode: result.exitCode, stderr: result.stderr)
        }
        log.info("Scrub complete for VM '\(vm)'")
    }

    /// Validates a recycled VM by running a battery of guest-exec checks.
    ///
    /// Returns:
    /// - ``RecycleOutcome/readyForNextJob`` if every check passes.
    /// - ``RecycleOutcome/needsRetry(reason:)`` for the **first**
    ///   failing check. (We stop at the first failure to keep the
    ///   exec surface area minimal and the reason diagnostic.)
    /// - ``RecycleOutcome/failed(reason:)`` if the guest agent
    ///   cannot be reached at all, or if a check throws — the VM
    ///   is structurally broken and cannot be retried.
    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> RecycleOutcome {
        for check in validationChecks {
            let result: GuestExecResult
            do {
                result = try await node.execInGuest(vm: vm, command: check.command, on: endpoint)
            } catch {
                log.error("Scrub validation structural failure for VM '\(vm)' on check '\(check.name)': \(error.localizedDescription)")
                return .failed(reason: "guest agent unreachable during check '\(check.name)': \(error.localizedDescription)")
            }
            if result.exitCode != 0 {
                log.info("Scrub validation: VM '\(vm)' failed check '\(check.name)' (exit \(result.exitCode))")
                return .needsRetry(reason: check.name)
            }
        }
        return .readyForNextJob
    }

    /// Recycles the VM and validates the result. If validation does
    /// not return ``RecycleOutcome/readyForNextJob``, destroys the VM
    /// to prevent dirty reuse.
    ///
    /// When a ``ReusePolicy`` is provided and ``ReusePolicy/warmPoolAllowed``
    /// is `false`, the VM is destroyed immediately without attempting a
    /// scrub — enforcing ephemeral mode in multi-tenant deployments.
    ///
    /// This is the only method callers should use. Direct calls to
    /// `recycle()` without validation are unsafe for production.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to recycle.
    ///   - source: The source template name (unused by scrub, but required by the protocol).
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    ///   - reusePolicy: Optional reuse policy. When warm-pool reuse is
    ///     disallowed, the VM is destroyed instead of recycled.
    /// - Returns: ``RecycleResult/clean`` if validation passes,
    ///   ``RecycleResult/destroyed`` if validation failed or reuse
    ///   is disallowed.
    public func recycleWithValidation(
        vm: String,
        source: String,
        using node: any NodeClient,
        on endpoint: URL,
        reusePolicy: ReusePolicy? = nil
    ) async throws -> RecycleResult {
        // If reuse policy forbids warm-pool reuse, destroy immediately.
        if let policy = reusePolicy, !policy.warmPoolAllowed {
            log.info("VM '\(vm)' warm-pool reuse disallowed by policy — destroying")
            try await node.stop(vm: vm, on: endpoint)
            try await node.delete(vm: vm, on: endpoint)
            return .destroyed
        }

        try await recycle(vm: vm, source: source, using: node, on: endpoint)
        let outcome = try await validate(vm: vm, using: node, on: endpoint)
        switch outcome {
        case .readyForNextJob:
            log.info("VM '\(vm)' passed scrub validation")
            return .clean
        case .needsRetry(let reason):
            log.error("VM '\(vm)' failed scrub validation — destroying. Reason: \(reason)")
            try await node.stop(vm: vm, on: endpoint)
            try await node.delete(vm: vm, on: endpoint)
            return .destroyed
        case .failed(let reason):
            log.error("VM '\(vm)' structural scrub failure — destroying. Reason: \(reason)")
            try await node.stop(vm: vm, on: endpoint)
            try await node.delete(vm: vm, on: endpoint)
            return .destroyed
        }
    }
}
