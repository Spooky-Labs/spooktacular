import Testing
import SpooktacularCore
@testable import SpooktacularApplication

@Suite("GitHubRunnerTemplate (Linux)")
struct GitHubRunnerTemplateLinuxTests {

    @Test("linux runner script: latest arm64 tarball, dedicated user, systemd, token embedded")
    func shape() {
        let script = GitHubRunnerTemplate.scriptContent(
            for: .linux, repo: "o/r", token: "REGTOK",
            ephemeral: true, runnerName: "e2e"
        )
        #expect(script.contains("useradd"))
        #expect(script.contains("actions/runner/releases/latest"))   // resolved at runtime
        #expect(script.contains("linux-arm64"))
        #expect(script.contains("TOKEN='REGTOK'"))
        #expect(script.contains("--ephemeral"))
        #expect(script.contains("Restart=no"))
        #expect(script.contains("systemctl enable --now"))
        #expect(script.contains("User=runner"))
        #expect(script.contains("sudo -u \"$RUNNER_USER\" ./config.sh"))
        #expect(!script.contains("launchctl"))
        // Dependency-free tarball resolution (grep, not python3) — the
        // same robustness the macOS variant needs, kept in lockstep.
        #expect(!script.contains("python3 -c"))
        #expect(script.contains("grep -oE"))
        #expect(script.contains("actions-runner-linux-arm64-"))
    }

    @Test("persistent linux runner restarts; ephemeral does not")
    func restartPolicy() {
        let persistent = GitHubRunnerTemplate.scriptContent(
            for: .linux, repo: "o/r", token: "T", ephemeral: false
        )
        #expect(persistent.contains("Restart=always"))
        #expect(!persistent.contains("--ephemeral"))
    }

    @Test("macOS content is unchanged by the OS-aware entry point")
    func macOSStable() {
        let viaOSEntry = GitHubRunnerTemplate.scriptContent(
            for: .macOS, repo: "o/r", token: "T",
            labels: ["a", "b"], ephemeral: false, runnerName: "n"
        )
        let direct = GitHubRunnerTemplate.scriptContent(
            repo: "o/r", token: "T",
            labels: ["a", "b"], ephemeral: false, runnerName: "n"
        )
        #expect(viaOSEntry == direct)
        #expect(viaOSEntry.contains("launchctl"))
        #expect(viaOSEntry.contains("sudo -u"))
    }
}
