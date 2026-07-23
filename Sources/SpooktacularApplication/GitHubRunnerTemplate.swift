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

    /// OS-aware entry point: routes to the macOS (launchd) or Linux
    /// (systemd) bootstrap. The macOS output is byte-identical to
    /// ``scriptContent(repo:token:labels:ephemeral:runnerName:)``.
    ///
    /// - Parameters:
    ///   - os: The guest operating system the script targets.
    ///   - repo: The GitHub repository in `owner/repo` format.
    ///   - token: The runner registration token.
    ///   - labels: Additional runner labels.
    ///   - ephemeral: Whether the runner exits after one job.
    ///   - runnerName: An optional `config.sh --name` value.
    public static func scriptContent(
        for os: GuestOS,
        repo: String,
        token: String,
        labels: [String] = [],
        ephemeral: Bool = false,
        runnerName: String? = nil
    ) -> String {
        switch os {
        case .macOS:
            scriptContent(
                repo: repo, token: token, labels: labels,
                ephemeral: ephemeral, runnerName: runnerName
            )
        case .linux:
            linuxScriptContent(
                repo: repo, token: token, labels: labels,
                ephemeral: ephemeral, runnerName: runnerName
            )
        }
    }

    /// Builds the shared `config.sh` argument line. Every interpolated
    /// value is escaped individually via ``shellEscapeSingleQuotes(_:)``
    /// — labels *before* joining, so a quote inside one label can't
    /// break out of the joined argument.
    private static func buildConfigLine(
        labels: [String],
        ephemeral: Bool,
        runnerName: String?
    ) -> String {
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

        return configFlags.joined(separator: " ")
    }

    /// Generates the shell script content for a GitHub Actions runner
    /// (macOS/launchd variant).
    ///
    /// Extracted as a separate method for testability.
    ///
    /// Every interpolated value — repo, token, runner name, and
    /// each label — is escaped individually via
    /// ``shellEscapeSingleQuotes(_:)`` before being embedded (see
    /// ``buildConfigLine(labels:ephemeral:runnerName:)``).
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
        let configLine = buildConfigLine(
            labels: labels, ephemeral: ephemeral, runnerName: runnerName
        )

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

    /// The Linux bootstrap: same design decisions as macOS —
    /// network wait, runtime-latest tarball from GitHub's API,
    /// direct `sudo -u` invocations (no nested `bash -c`
    /// re-parsing), `config.sh` never as root, and the long-running
    /// process handed to the service manager (systemd here, launchd
    /// there). Runs as root via cloud-init's `runcmd` on first boot.
    private static func linuxScriptContent(
        repo: String,
        token: String,
        labels: [String],
        ephemeral: Bool,
        runnerName: String?
    ) -> String {
        let safeRepo = shellEscapeSingleQuotes(repo)
        let safeToken = shellEscapeSingleQuotes(token)
        let configLine = buildConfigLine(
            labels: labels, ephemeral: ephemeral, runnerName: runnerName
        )
        // Ephemeral runners deregister after one job — restarting
        // run.sh would spin an unregistered process (mirrors the
        // launchd KeepAlive choice).
        let restart = ephemeral ? "no" : "always"

        return """
        #!/bin/bash
        # GitHub Actions runner bootstrap — executed as root by
        # cloud-init (runcmd) on first boot. Configures the runner as
        # the runner user and hands it off to systemd, then exits.
        set -euo pipefail

        REPO='\(safeRepo)'
        TOKEN='\(safeToken)'
        RUNNER_USER="\(Self.runnerAccountUsername)"
        RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"

        # DHCP may still be settling on first boot — give the network
        # up to two minutes before hitting the GitHub API.
        for _ in $(seq 1 60); do
            curl -fsS --max-time 10 https://api.github.com >/dev/null 2>&1 && break
            sleep 2
        done

        id "$RUNNER_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$RUNNER_USER"
        mkdir -p "$RUNNER_DIR"
        chown "$RUNNER_USER":"$RUNNER_USER" "$RUNNER_DIR"
        cd "$RUNNER_DIR"

        TARBALL_URL=$(curl -fsSL --max-time 30 https://api.github.com/repos/actions/runner/releases/latest \\
            | python3 -c 'import json,sys;print(next(a["browser_download_url"] for a in json.load(sys.stdin)["assets"] if "linux-arm64" in a["name"] and a["name"].endswith(".tar.gz")))')
        [ -n "$TARBALL_URL" ] || { echo "failed to resolve runner tarball URL" >&2; exit 1; }

        sudo -u "$RUNNER_USER" curl -fsSL --max-time 300 -o runner.tar.gz "$TARBALL_URL"
        sudo -u "$RUNNER_USER" tar xzf runner.tar.gz
        sudo -u "$RUNNER_USER" rm -f runner.tar.gz

        # Distro packages the runner needs (ships with the tarball;
        # root is required and we have it).
        ./bin/installdependencies.sh || true

        # config.sh refuses to run as root by default, and this
        # script deliberately never overrides that default.
        sudo -u "$RUNNER_USER" ./config.sh \(configLine)

        cat > /etc/systemd/system/actions-runner.service <<'UNIT'
        [Unit]
        Description=GitHub Actions runner (Spooktacular)
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=\(Self.runnerAccountUsername)
        WorkingDirectory=/home/\(Self.runnerAccountUsername)/actions-runner
        ExecStart=/home/\(Self.runnerAccountUsername)/actions-runner/run.sh
        Restart=\(restart)

        [Install]
        WantedBy=multi-user.target
        UNIT
        systemctl daemon-reload
        systemctl enable --now actions-runner.service
        """
    }

    /// Generates a Linux or macOS runner setup script staged in the
    /// script cache — the OS-aware counterpart of
    /// ``generate(repo:token:labels:ephemeral:runnerName:)``.
    public static func generate(
        for os: GuestOS,
        repo: String,
        token: String,
        labels: [String] = [],
        ephemeral: Bool = false,
        runnerName: String? = nil
    ) throws -> URL {
        try ScriptFile.writeToCache(
            script: scriptContent(
                for: os, repo: repo, token: token, labels: labels,
                ephemeral: ephemeral, runnerName: runnerName
            ),
            fileName: "github-runner-setup.sh"
        )
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
