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

    @Test("runner account username is consistent across script + service plist")
    func runnerAccountUsernameConsistency() {
        // Regression: the account was renamed admin → runner when
        // native guest provisioning (VZMacGuestProvisioningOptions)
        // replaced the OCR path, but the generated script kept
        // emitting RUNNER_USER="admin" and the runner LaunchDaemon
        // kept UserName=admin / WorkingDirectory=/Users/admin —
        // pointing the service at a user that no longer exists, so
        // the runner never registered. The configured user, the
        // service UserName, and its home path must all track the
        // account GuestProvisioningSpec actually creates.
        let user = GitHubRunnerTemplate.runnerAccountUsername
        #expect(user == "runner")
        #expect(script.contains("RUNNER_USER=\"\(user)\""))
        #expect(script.contains("<key>UserName</key><string>\(user)</string>"))
        #expect(script.contains("/Users/\(user)/actions-runner/run.sh"))
        // No lingering reference to the retired `admin` account.
        #expect(!script.contains("admin"))
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
    // runs as the runner user (GitHub's runner refuses
    // `--unattended` as root), and `run.sh` is handed to a
    // launchd LaunchDaemon rather than run in the foreground —
    // otherwise the script would block forever and the
    // provisioner would never archive the trigger.

    @Test("config.sh runs as the runner user via sudo -u, never as root")
    func scriptRunsConfigAsRunnerNotRoot() throws {
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

    @Test("every curl invocation is bounded with --max-time")
    func curlHasMaxTime() throws {
        let url = try GitHubRunnerTemplate.generate(repo: "o/r", token: "tok")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let s = try String(contentsOf: url, encoding: .utf8)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
        let curlLines = lines.filter { line in
            line.contains("curl") && !line.trimmingCharacters(in: .whitespaces).starts(with: "#")
        }
        #expect(!curlLines.isEmpty, "Script should contain curl invocations")
        for curlLine in curlLines {
            #expect(curlLine.contains("--max-time"), "curl line missing --max-time: \(curlLine)")
        }
    }

    @Test("empty TARBALL_URL triggers diagnostic message")
    func tarballUrlDiagnostic() {
        let s = GitHubRunnerTemplate.scriptContent(repo: "o/r", token: "t")
        #expect(s.contains("failed to resolve runner tarball URL"), "Script should diagnose empty TARBALL_URL")
    }

    // MARK: - Token-at-rest: guest-side archive redaction
    //
    // End-to-end token trace: this template embeds the live GitHub
    // registration token verbatim as a `TOKEN='...'` line (the
    // config.sh invocation needs it in-shell). The guest-side
    // provisioner LaunchDaemon (Resources/SpookProvisioner/spook-provision-runner.sh)
    // archives the script body to `first-boot.ran.sh` on the
    // read-write provisioning share for operator debugging — with
    // no host-side cleanup path, so a verbatim archive would leave
    // a live, unspent token sitting on host disk indefinitely. This
    // is a cross-file contract test: it reads the ACTUAL sed
    // pattern out of the runner script (not a hand-copied
    // duplicate) and runs the REAL `/usr/bin/sed` against a
    // template-generated script, so it fails if either side of the
    // contract drifts — the template changes the TOKEN= line shape,
    // or the runner script's redaction pattern regresses to a
    // verbatim `cp`.

    private func provisionerScriptSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repoRoot
            .appendingPathComponent("Resources")
            .appendingPathComponent("SpookProvisioner")
            .appendingPathComponent("spook-provision-runner.sh")
        return try String(contentsOf: scriptURL, encoding: .utf8)
    }

    @Test("spook-provision-runner.sh archives via sed, not a verbatim cp")
    func provisionerArchivesViaRedactingSed() throws {
        let source = try provisionerScriptSource()
        #expect(
            !source.contains(#"cp "${SCRIPT_PATH}" "${ARCHIVE_PATH}""#),
            "The archive step must not be a verbatim `cp` — that copies the live TOKEN= line straight to host-visible disk with no cleanup path."
        )
        #expect(
            source.contains(#"sed "s/^TOKEN=.*/TOKEN='[REDACTED]'/" "${SCRIPT_PATH}" > "${ARCHIVE_PATH}""#),
            "Expected spook-provision-runner.sh's archive step to redact the TOKEN= line via sed while writing ${ARCHIVE_PATH}."
        )
    }

    @Test("the runner script's actual sed pattern redacts a real generated TOKEN line")
    func sedPatternRedactsGeneratedToken() throws {
        let source = try provisionerScriptSource()
        guard let sedLine = source
            .components(separatedBy: "\n")
            .first(where: { $0.contains("sed") && $0.contains("ARCHIVE_PATH") })
        else {
            Issue.record("No sed-based archive line found in spook-provision-runner.sh.")
            return
        }
        // Extract the pattern between the first pair of double
        // quotes — the literal sed program text — so this test
        // exercises the SAME pattern the guest runs, not a
        // hand-copied duplicate that could silently drift from it.
        guard let firstQuote = sedLine.firstIndex(of: "\""),
              let secondQuote = sedLine[sedLine.index(after: firstQuote)...].firstIndex(of: "\"")
        else {
            Issue.record("Could not parse the sed pattern out of: \(sedLine)")
            return
        }
        let sedPattern = String(sedLine[sedLine.index(after: firstQuote)..<secondQuote])

        let token = "ghs_LIVETOKENVALUE1234567890abcdef"
        let generated = GitHubRunnerTemplate.scriptContent(repo: "acme/widgets", token: token)
        try #require(
            generated.contains("TOKEN='\(token)'"),
            "Precondition: the generated script must actually embed the live token, or this test proves nothing."
        )

        let tmp = TempDirectory()
        let scriptPath = tmp.file("first-boot.sh")
        try generated.write(to: scriptPath, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sed")
        process.arguments = [sedPattern, scriptPath.path]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        try process.run()
        process.waitUntilExit()
        let archived = String(
            data: outPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(process.terminationStatus == 0)
        #expect(
            !archived.contains(token),
            "The live registration token must never survive into the archived copy."
        )
        #expect(
            archived.contains("TOKEN='[REDACTED]'"),
            "The archived copy should keep a redacted TOKEN line so its structure still reads like the original for debugging."
        )
        // Everything else survives byte-for-byte — only the TOKEN
        // line changes.
        #expect(archived.contains("REPO='acme/widgets'"))
        #expect(archived.contains(#"sudo -u "$RUNNER_USER" ./config.sh"#))
        #expect(archived.contains("launchctl bootstrap system"))
    }
}
