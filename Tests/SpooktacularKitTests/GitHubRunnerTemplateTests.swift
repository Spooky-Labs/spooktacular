import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("GitHub Runner Template", .tags(.template, .integration))
struct GitHubRunnerTemplateTests {

    let script = GitHubRunnerTemplate.scriptContent(
        repo: "myorg/myrepo",
        token: "TESTTOKEN123",
        labels: ["macos", "arm64"],
        ephemeral: true
    )

    @Suite("Script Structure")
    struct Structure {
        let script = GitHubRunnerTemplate.scriptContent(repo: "o/r", token: "t")

        @Test("starts with bash shebang")
        func shebang() { #expect(script.hasPrefix("#!/bin/bash")) }

        @Test("uses set -euo pipefail for safety")
        func strictMode() { #expect(script.contains("set -euo pipefail") || script.contains("set -e")) }
    }

    @Test("script includes all required elements",
          arguments: [
              "REPO='myorg/myrepo'",
              "TOKEN='TESTTOKEN123'",
              "https://github.com/$REPO",
              "api.github.com/repos/actions/runner/releases/latest",
              "osx-arm64",
              "--unattended",
              "--replace",
              "config.sh",
              "run.sh",
          ])
    func requiredElement(expected: String) {
        #expect(script.contains(expected), "Script missing: \(expected)")
    }

    @Test("ephemeral flag included when ephemeral is true")
    func ephemeralFlag() {
        #expect(script.contains("--ephemeral"))
    }

    @Test("ephemeral flag excluded when ephemeral is false")
    func noEphemeralWhenDisabled() {
        let nonEphemeral = GitHubRunnerTemplate.scriptContent(
            repo: "o/r", token: "t", ephemeral: false
        )
        #expect(!nonEphemeral.contains("--ephemeral"))
    }

    @Test("labels included when provided")
    func labelsIncluded() {
        #expect(script.contains("macos,arm64"))
    }

    @Test("labels excluded when nil")
    func noLabelsWhenNil() {
        let noLabels = GitHubRunnerTemplate.scriptContent(
            repo: "o/r", token: "t"
        )
        #expect(!noLabels.contains("--labels"))
    }

    @Test("token is properly shell-escaped")
    func tokenEscaping() {
        let dangerous = GitHubRunnerTemplate.scriptContent(
            repo: "o/r", token: "tok'en\"with$pecial"
        )
        // Token should be wrapped in single quotes with escaping
        #expect(!dangerous.contains("tok'en"))
    }

    @Test("single-quoted labels are escaped individually")
    func labelWithSingleQuoteDoesNotBreakQuoting() {
        // The historic bug: labels were joined THEN escaped, which
        // let a single-quote in one label break out of the outer
        // quoting and let shell code leak in.
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t",
            labels: ["foo'bar", "baz"]
        )
        // The bad label must be POSIX-escaped as `foo'\''bar`
        // inside the single-quoted --labels argument.
        #expect(script.contains("foo'\\''bar,baz"))
        // And there must NEVER be an unescaped single-quote that
        // closes the --labels argument prematurely.
        #expect(!script.contains("'foo'bar"))
    }

    @Test("empty labels array omits the --labels flag")
    func emptyLabels() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t",
            labels: []
        )
        #expect(!script.contains("--labels"))
    }

    // MARK: - Root provisioner compatibility (v2)
    //
    // The provisioner LaunchDaemon runs this script as root on
    // first boot and waits for it to exit before archiving the
    // trigger file. These tests pin the v2 contract: config.sh
    // runs as the admin user (GitHub's runner refuses
    // `--unattended` as root), and `run.sh` is handed to a
    // launchd LaunchDaemon rather than run in the foreground —
    // otherwise the script would block forever and the
    // provisioner would never archive the trigger.

    @Test("config.sh runs as the admin user via sudo -u, never as root")
    func scriptRunsConfigAsAdminNotRoot() throws {
        let url = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = try String(contentsOf: url, encoding: .utf8)
        #expect(s.contains(#"sudo -u "$RUNNER_USER""#))
        #expect(!s.contains("RUNNER_ALLOW_RUNASROOT"))
    }

    @Test("script installs a LaunchDaemon for run.sh and exits without blocking")
    func scriptInstallsLaunchDaemonAndDoesNotBlock() throws {
        let url = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = try String(contentsOf: url, encoding: .utf8)
        #expect(s.contains("/Library/LaunchDaemons/com.spooktacular.github-runner.plist"))
        #expect(s.contains("launchctl bootstrap system"))
        #expect(s.contains("<key>UserName</key>"))
        // run.sh must only appear inside the plist's ProgramArguments,
        // never invoked directly in the foreground.
        #expect(!s.contains("./run.sh\n"))
    }

    @Test("ephemeral runners get a non-persistent LaunchDaemon")
    func ephemeralDisablesKeepAlive() throws {
        let ephURL = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok", ephemeral: true)
        defer { try? FileManager.default.removeItem(at: ephURL.deletingLastPathComponent()) }
        let eph = try String(contentsOf: ephURL, encoding: .utf8)
        #expect(eph.contains("--ephemeral"))
        #expect(eph.contains("<key>KeepAlive</key>\n    <false/>"))

        let persistentURL = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok")
        defer { try? FileManager.default.removeItem(at: persistentURL.deletingLastPathComponent()) }
        let persistent = try String(contentsOf: persistentURL, encoding: .utf8)
        #expect(persistent.contains("<key>KeepAlive</key>\n    <true/>"))
    }

    @Test("runner name flows into the config.sh --name argument")
    func runnerNameFlowsToConfig() throws {
        let url = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok", runnerName: "runner-01")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = try String(contentsOf: url, encoding: .utf8)
        #expect(s.contains("--name 'runner-01'"))
    }

    @Test("script waits for the network before hitting the GitHub API")
    func waitsForNetworkBeforeCurl() throws {
        let url = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = try String(contentsOf: url, encoding: .utf8)
        let apiIndex = s.range(of: "api.github.com")
            .map { s.distance(from: s.startIndex, to: $0.lowerBound) } ?? 0
        let waitIndex = s.range(of: "network wait")
            .map { s.distance(from: s.startIndex, to: $0.lowerBound) } ?? Int.max
        #expect(apiIndex > waitIndex)
    }
}
