import Foundation
import Testing

/// Regression tests for `spooktacular-cli`'s `Create` command:
/// `--json` mode promises "a machine-parsable success payload" on
/// stdout — exactly one JSON document (the success payload via
/// `printJSON`, or an error document via `printJSONError`), nothing
/// else. Several validation guards and helper functions used to
/// print unguarded, unstyled text straight to stdout regardless of
/// `--json`, corrupting that single-document contract (confirmed
/// empirically: `spook create x --github-runner --json` with a
/// missing `--github-repo` printed raw `✗ ...` text with no JSON
/// wrapping at all before the fix).
///
/// `Create` lives in the `spooktacular-cli` executable target, which
/// (like `AppState` in the `Spooktacular` GUI target) has no
/// `@testable import` path from this test target — driving the full
/// `ParsableCommand` would require shelling out to a built binary
/// per test, which is exactly what was done manually to verify this
/// fix (see the final-fix report). These are source-level
/// regression guards, matching the established pattern in
/// `GuestToolsProvisioningGateTests` / `GuestToolsInstalledCleanupTests`
/// for exactly the same reason.
@Suite("Create --json purity")
struct CreateJSONPurityTests {

    private func readCreateSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let createFile = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("spooktacular-cli")
            .appendingPathComponent("Commands")
            .appendingPathComponent("Create.swift")
        return try String(contentsOf: createFile, encoding: .utf8)
    }

    @Test("--github-repo validation guard is --json aware")
    func githubRepoGuardIsJSONAware() throws {
        let source = try readCreateSource()
        guard let range = source.range(of: "guard let repo = githubRepo else {") else {
            Issue.record("--github-repo guard not found in Create.swift — test is obsolete.")
            return
        }
        let body = String(source[range.upperBound...].prefix(600))
        #expect(
            body.contains("if json {") && body.contains("printJSONError"),
            "The --github-repo-missing guard must route through printJSONError in --json mode instead of printing raw styled text straight to stdout."
        )
    }

    @Test("--github-token-keychain validation guard is --json aware")
    func githubTokenKeychainGuardIsJSONAware() throws {
        let source = try readCreateSource()
        guard let range = source.range(of: "guard let account = githubTokenKeychain else {") else {
            Issue.record("--github-token-keychain guard not found in Create.swift — test is obsolete.")
            return
        }
        let body = String(source[range.upperBound...].prefix(600))
        #expect(
            body.contains("if json {") && body.contains("printJSONError"),
            "The --github-token-keychain-missing guard must route through printJSONError in --json mode instead of printing raw styled text straight to stdout."
        )
    }

    @Test("cleanupRunnerVMAfterStop takes a json flag and gates its ephemeral-destroyed print")
    func cleanupRunnerVMAfterStopIsJSONAware() throws {
        let source = try readCreateSource()
        guard let range = source.range(of: "private func cleanupRunnerVMAfterStop(") else {
            Issue.record("cleanupRunnerVMAfterStop(_:) not found in Create.swift — test is obsolete.")
            return
        }
        let signatureAndBody = String(source[range.lowerBound...].prefix(900))
        #expect(
            signatureAndBody.contains("json: Bool"),
            "cleanupRunnerVMAfterStop must take a json flag — its 'Ephemeral VM destroyed.' print can land AFTER the create flow's single JSON payload on the mainline stop path, corrupting --json output if unconditional."
        )
        #expect(
            signatureAndBody.contains("if !json {"),
            "cleanupRunnerVMAfterStop's ephemeral-destroyed print must be gated on !json."
        )
    }

    @Test("provisioner daemon injection's progress lines are gated on !json")
    func provisionerDaemonInjectionProgressIsJSONAware() throws {
        let source = try readCreateSource()
        guard let range = source.range(of: "try DiskInjector.installProvisionerDaemon(") else {
            Issue.record("DiskInjector.installProvisionerDaemon call not found in Create.swift — test is obsolete.")
            return
        }
        let body = String(source[range.upperBound...].prefix(1200))
        #expect(
            body.contains(#"if !json { print(Style.success("✓ Provisioner daemon injected.")) }"#),
            "The provisioner daemon injection's success line must be gated on !json."
        )
        #expect(
            body.contains(#"if !json { print(Style.dim("  Provisioner assets not found"#),
            "The provisioner-assets-not-found soft warning must be gated on !json."
        )
    }
}
