import Testing
import Foundation
@testable import SpooktacularKit

@Suite("GitHubRunnerTemplate")
struct GitHubRunnerTemplateTests {

    // MARK: - Script Content

    @Test("Script contains the repository URL")
    func containsRepoURL() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "myorg/myrepo",
            token: "ATOKEN123"
        )
        #expect(script.contains("https://github.com/myorg/myrepo"))
    }

    @Test("Script contains the registration token")
    func containsToken() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "myorg/myrepo",
            token: "ATOKEN123"
        )
        #expect(script.contains("ATOKEN123"))
    }

    @Test("Script starts with a shebang line")
    func hasShebang() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t"
        )
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    @Test("Script downloads the latest runner from GitHub API")
    func downloadsRunner() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t"
        )
        #expect(script.contains("api.github.com/repos/actions/runner/releases/latest"))
        #expect(script.contains("osx-arm64"))
    }

    @Test("Script runs config.sh with --unattended and --replace")
    func configFlags() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t"
        )
        #expect(script.contains("./config.sh"))
        #expect(script.contains("--unattended"))
        #expect(script.contains("--replace"))
    }

    @Test("Script runs run.sh to start the runner")
    func startsRunner() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t"
        )
        #expect(script.contains("./run.sh"))
    }

    @Test("Ephemeral mode adds --ephemeral flag")
    func ephemeralFlag() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t",
            ephemeral: true
        )
        #expect(script.contains("--ephemeral"))
    }

    @Test("Non-ephemeral mode does not include --ephemeral flag")
    func noEphemeralFlag() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t",
            ephemeral: false
        )
        #expect(!script.contains("--ephemeral"))
    }

    @Test("Custom labels are included in config.sh")
    func customLabels() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t",
            labels: ["gpu", "build"]
        )
        #expect(script.contains("--labels"))
        #expect(script.contains("gpu,build"))
    }

    @Test("No labels when array is empty")
    func noLabels() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t",
            labels: []
        )
        #expect(!script.contains("--labels"))
    }

    @Test("Script uses set -euo pipefail for safety")
    func strictMode() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t"
        )
        #expect(script.contains("set -euo pipefail"))
    }

    @Test("Script creates actions-runner directory")
    func createsDirectory() {
        let script = GitHubRunnerTemplate.scriptContent(
            repo: "o/r",
            token: "t"
        )
        #expect(script.contains("mkdir -p actions-runner"))
    }

    // MARK: - File Generation

    @Test("generate() creates a file on disk")
    func generatesFile() throws {
        let url = try GitHubRunnerTemplate.generate(
            repo: "myorg/myrepo",
            token: "TOKEN"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Generated file is executable")
    func fileIsExecutable() throws {
        let url = try GitHubRunnerTemplate.generate(
            repo: "myorg/myrepo",
            token: "TOKEN"
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test("Generated file content matches scriptContent()")
    func fileContentMatchesScript() throws {
        let url = try GitHubRunnerTemplate.generate(
            repo: "org/repo",
            token: "TOK",
            labels: ["ci"],
            ephemeral: true
        )
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fileContent = try String(contentsOf: url, encoding: .utf8)
        let expected = GitHubRunnerTemplate.scriptContent(
            repo: "org/repo",
            token: "TOK",
            labels: ["ci"],
            ephemeral: true
        )
        #expect(fileContent == expected)
    }
}
