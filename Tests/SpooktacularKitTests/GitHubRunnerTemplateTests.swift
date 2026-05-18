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
}
