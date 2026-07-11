import Foundation
import SpooktacularCore

/// Generates the first-boot provisioning script for GitHub Actions
/// runner VMs.
///
/// When `spook create` is invoked with `--github-runner`, this
/// template generates a shell script that becomes the guest's
/// `first-boot.sh` trigger, consumed by the Spooktacular
/// provisioner LaunchDaemon (see `Resources/SpookProvisioner/spook-provision-runner.sh`).
/// That daemon runs the script **as root** on first boot and
/// blocks — waiting for it to exit — before archiving the trigger
/// file, so the script's own root-safety and non-blocking exit are
/// load-bearing, not stylistic:
///
/// 1. Downloads the latest GitHub Actions runner for macOS ARM64
///    and configures it as the `runner` user via `sudo -u` — the
///    runner's `config.sh` refuses to run as root unless
///    `RUNNER_ALLOW_RUNASROOT` is set, which this script never
///    sets.
/// 2. Installs a `UserName`-scoped LaunchDaemon
///    (`com.spooktacular.github-runner`) that runs `run.sh` as the
///    `runner` user, then `launchctl bootstrap`s it and **exits**.
///    The runner's long-lived process therefore lives under
///    launchd, not under the provisioner's child-process tree —
///    the provisioner script would block forever, and the trigger
///    file would never be archived, if `run.sh` ran in the
///    foreground here.
/// 3. `KeepAlive` is `true` for persistent runners (launchd
///    restarts `run.sh` if it exits) and `false` for ephemeral
///    runners (a one-job runner that GitHub has already
///    deregistered should not be relaunched).
///
/// ## Usage
///
/// ```swift
/// let url = try GitHubRunnerTemplate.generate(
///     repo: "myorg/myrepo",
///     token: "AABCDEF..."
/// )
/// // Inject `url` as the VM's first-boot.sh via DiskInjector.
/// ```
///
/// ## Security
///
/// The registration token is embedded in the script file. The
/// script is written to a temporary directory with restricted
/// permissions. Tokens are short-lived (1 hour) per GitHub's
/// design, limiting the exposure window. The generated LaunchDaemon
/// plist is written via a single-quoted heredoc (`<<'PLIST'`) so no
/// shell variable — including `$TOKEN` — is ever expanded into it.
public enum GitHubRunnerTemplate {

    /// The macOS account the runner is configured and run under.
    ///
    /// Native guest provisioning (``GuestProvisioningSpec``) creates
    /// this account as an admin user on first boot; the generated
    /// first-boot script and the runner LaunchDaemon must reference
    /// the **same** name. Both derive it from this single constant
    /// rather than hardcoding a literal — they drifted once, when the
    /// account was renamed `admin` → `runner` as the OCR path was
    /// replaced by native provisioning but the generated script kept
    /// emitting `admin`, leaving the runner service pointed at a user
    /// that no longer exists.
    public static let runnerAccountUsername = "runner"

    /// Generates a GitHub Actions runner setup script.
    ///
    /// Creates a temporary shell script that downloads and
    /// configures a GitHub Actions self-hosted runner as the
    /// `runner` user, then hands it off to a launchd LaunchDaemon
    /// and exits without blocking.
    ///
    /// - Parameters:
    ///   - repo: The GitHub repository in `owner/repo` format
    ///     (e.g., `"myorg/myrepo"`).
    ///   - token: The runner registration token obtained from
    ///     GitHub's API or the repository settings page.
    ///   - labels: Additional labels for the runner. The runner
    ///     always includes the `self-hosted`, `macOS`, and `ARM64`
    ///     labels. Defaults to an empty array.
    ///   - ephemeral: If `true`, the runner exits after completing
    ///     one job, and its LaunchDaemon is installed without
    ///     `KeepAlive` so launchd does not relaunch a deregistered
    ///     runner. Defaults to `false`.
    ///   - runnerName: An optional display name passed to
    ///     `config.sh --name`. When `nil`, GitHub assigns a default
    ///     name derived from the host. Defaults to `nil`.
    /// - Returns: A file URL pointing to the generated script in
    ///   a temporary directory.
    /// - Throws: An error if the script cannot be written to disk.
    public static func generate(
        repo: String,
        token: String,
        labels: [String] = [],
        ephemeral: Bool = false,
        runnerName: String? = nil
    ) throws -> URL {
        let url = try ScriptFile.writeToCache(
            script: scriptContent(
                repo: repo,
                token: token,
                labels: labels,
                ephemeral: ephemeral,
                runnerName: runnerName
            ),
            fileName: "github-runner-setup.sh"
        )
        return url
    }

    /// Generates the shell script content for a GitHub Actions runner.
    ///
    /// Extracted as a separate method for testability.
    ///
    /// Every interpolated value — repo, token, runner name, and
    /// each label — is escaped individually via
    /// ``shellEscapeSingleQuotes(_:)`` before being embedded. Labels
    /// in particular must be escaped *before* joining: escaping the
    /// already-joined string would let a single-quote inside one
    /// label break out of the surrounding quoting — a classic
    /// metacharacter bug.
    ///
    /// - Parameters:
    ///   - repo: The GitHub repository in `owner/repo` format.
    ///   - token: The runner registration token.
    ///   - labels: Additional runner labels.
    ///   - ephemeral: Whether the runner exits after one job.
    ///   - runnerName: An optional `config.sh --name` value.
    /// - Returns: The complete shell script as a string.
    public static func scriptContent(
        repo: String,
        token: String,
        labels: [String] = [],
        ephemeral: Bool = false,
        runnerName: String? = nil
    ) -> String {
        let safeRepo = shellEscapeSingleQuotes(repo)
        let safeToken = shellEscapeSingleQuotes(token)

        var configFlags = [
            "--url \"https://github.com/$REPO\"",
            "--token \"$TOKEN\"",
            "--unattended",
            "--replace",
        ]

        if let runnerName, !runnerName.isEmpty {
            configFlags.append("--name '\(shellEscapeSingleQuotes(runnerName))'")
        }

        if !labels.isEmpty {
            // Escape each label *individually* first, then join on a
            // comma, then wrap the whole thing in outer single quotes.
            // `foo'bar` must become `foo'\''bar`; joining raw labels
            // and escaping only once lets `foo'bar,baz` slip through
            // as two quoted segments, breaking the argument.
            let escapedLabels = labels
                .map(shellEscapeSingleQuotes)
                .joined(separator: ",")
            configFlags.append("--labels '\(escapedLabels)'")
        }

        if ephemeral {
            configFlags.append("--ephemeral")
        }

        let configLine = configFlags.joined(separator: " ")

        // Persistent runners: launchd relaunches `run.sh` if it
        // exits, so a job crash or `run.sh` restart doesn't strand
        // the VM without a registered runner. Ephemeral runners
        // exit after one job and GitHub deregisters them on that
        // exit — relaunching would just spin up an unregistered
        // process, so `KeepAlive` is off.
        let keepAliveTag = ephemeral ? "<false/>" : "<true/>"

        return """
        #!/bin/bash
        # GitHub Actions runner bootstrap — executed as root by the
        # Spooktacular provisioner LaunchDaemon on first boot.
        # Configures the runner as the runner user and hands it off
        # to launchd, then exits without blocking on run.sh.
        set -euo pipefail

        REPO='\(safeRepo)'
        TOKEN='\(safeToken)'
        RUNNER_USER="\(Self.runnerAccountUsername)"
        RUNNER_DIR="/Users/${RUNNER_USER}/actions-runner"

        # network wait: native guest provisioning has already created
        # the account by the time this LaunchDaemon runs, but DHCP may
        # still be settling on first boot, so give the network up to
        # two minutes to come up before hitting the GitHub API.
        for _ in $(seq 1 60); do
            curl -fsS --max-time 10 https://api.github.com >/dev/null 2>&1 && break
            sleep 2
        done

        sudo -u "$RUNNER_USER" mkdir -p "$RUNNER_DIR"
        cd "$RUNNER_DIR"

        TARBALL_URL=$(curl -fsSL --max-time 30 https://api.github.com/repos/actions/runner/releases/latest \\
            | /usr/bin/python3 -c 'import json,sys;print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if "osx-arm64" in a["name"] and a["name"].endswith(".tar.gz")))')
        [ -n "$TARBALL_URL" ] || { echo "failed to resolve runner tarball URL" >&2; exit 1; }

        # `cd` runs once, here, in this (root) shell — the working
        # directory is inherited by every `sudo -u` child below.
        # Each command is invoked directly (never wrapped in a
        # nested `bash -c "...$VAR..."`), so REPO/TOKEN/TARBALL_URL
        # are expanded and quoted exactly once. A nested double-quoted
        # `bash -c` would expand the variable in this shell and hand
        # the raw, unescaped result to a second shell for re-parsing —
        # a single quote in the token would break out of that second
        # parse (verified empirically), defeating the escaping above.
        sudo -u "$RUNNER_USER" curl -fsSL --max-time 300 -o runner.tar.gz "$TARBALL_URL"
        sudo -u "$RUNNER_USER" tar xzf runner.tar.gz
        sudo -u "$RUNNER_USER" rm -f runner.tar.gz

        # config.sh refuses to run as root by default, and this
        # script deliberately never overrides that default — run it
        # as the runner user instead.
        sudo -u "$RUNNER_USER" ./config.sh \(configLine)

        # Hand the long-running runner process to launchd rather than
        # running `run.sh` in the foreground here, which would block
        # the provisioner (and therefore first-boot completion)
        # forever. The heredoc is single-quoted so no shell variable
        # — including $TOKEN — is ever expanded into the plist.
        cat > /Library/LaunchDaemons/com.spooktacular.github-runner.plist <<'PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>Label</key><string>com.spooktacular.github-runner</string>
            <key>UserName</key><string>\(Self.runnerAccountUsername)</string>
            <key>WorkingDirectory</key><string>/Users/\(Self.runnerAccountUsername)/actions-runner</string>
            <key>ProgramArguments</key><array><string>/Users/\(Self.runnerAccountUsername)/actions-runner/run.sh</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            \(keepAliveTag)
            <key>StandardOutPath</key><string>/var/log/spooktacular-runner.log</string>
            <key>StandardErrorPath</key><string>/var/log/spooktacular-runner.err.log</string>
        </dict></plist>
        PLIST

        chown root:wheel /Library/LaunchDaemons/com.spooktacular.github-runner.plist
        chmod 644 /Library/LaunchDaemons/com.spooktacular.github-runner.plist
        launchctl bootstrap system /Library/LaunchDaemons/com.spooktacular.github-runner.plist || true
        """
    }

    /// Escapes a string for safe embedding inside a single-quoted
    /// POSIX shell argument.
    ///
    /// Wraps an embedded `'` as `'\''` — close the quote, emit an
    /// escaped literal quote, reopen the quote — the standard,
    /// correct way to place a literal single quote inside
    /// single-quoted shell text. Applied individually to every
    /// interpolated value (repo, token, runner name, each label)
    /// before it is embedded in the generated script.
    ///
    /// - Parameter value: The raw string to escape.
    /// - Returns: `value` with every `'` replaced by `'\''`.
    private static func shellEscapeSingleQuotes(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }

}
