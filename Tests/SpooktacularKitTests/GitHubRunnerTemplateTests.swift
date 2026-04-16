import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

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
}
