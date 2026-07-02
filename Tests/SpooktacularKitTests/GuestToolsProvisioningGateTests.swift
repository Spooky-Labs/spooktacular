import Foundation
import Testing

/// Regression test for the Phase-4-late bug where the GUI
/// `runMacOSCreate` path guarded `provisionBundleForCreate`
/// on `request.userScriptURL != nil` — a holdover from the
/// legacy world where a user-supplied script was the ONLY
/// provisioning trigger. After the Guest Tools refactor,
/// that guard meant every macOS VM created without a custom
/// script got `.installed` ignored: the Guest Tools bundle
/// never made it into the guest's `/Applications/`, and the
/// toolbar pill would stay gray forever.
///
/// Like the `AgentHTTPServer` resilience test, we grep at
/// the source level — this class of bug hides in the gate
/// expression that decides whether provisioning runs at
/// all. An integration test would require a full VM create
/// pipeline; the source-level assertion catches the
/// anti-pattern for a fraction of the cost.
@Suite("GuestTools provisioning gate")
struct GuestToolsProvisioningGateTests {

    @Test("runMacOSCreate triggers provisioning on Guest Tools install, not just on userScript")
    func provisioningNotGatedOnUserScriptOnly() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appStateFile = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Spooktacular")
            .appendingPathComponent("AppState.swift")
        let source = try String(contentsOf: appStateFile, encoding: .utf8)

        // The anti-pattern: a bare `userScriptURL != nil`
        // guard immediately preceding
        // `provisionBundleForCreate`. The fixed code uses a
        // `needsProvisioning` OR-expression that also
        // considers `installsAppBundle`. We assert the
        // fixed shape exists.
        #expect(
            source.contains("installsAppBundle"),
            "AppState.runMacOSCreate must consult guestToolsInstall.installsAppBundle when deciding whether to provision — not just the userScript URL. Otherwise VMs created with `.installed` but no user script skip Guest Tools install entirely."
        )

        // Also assert we're NOT re-introducing the old
        // single-condition guard that caused the bug.
        // Match literal text (no regex magic to maintain).
        let bareGuard = "if request.userScriptURL != nil {\n                updateCreation"
        #expect(
            !source.contains(bareGuard),
            "Detected the legacy `if request.userScriptURL != nil { updateCreation(...) }` gate that suppresses Guest Tools install when no user script is supplied. Restore the `needsProvisioning` OR-gate."
        )
    }

    @Test("provisionBundleForCreate honors guestToolsInstall.installsAppBundle")
    func provisionFunctionReadsInstallMode() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appStateFile = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Spooktacular")
            .appendingPathComponent("AppState.swift")
        let source = try String(contentsOf: appStateFile, encoding: .utf8)

        // The provisionBundleForCreate body must reach
        // DiskInjector.installGuestTools via an
        // `installsAppBundle` check. If someone removes the
        // check, either Guest Tools runs for `.disabled` VMs
        // (bad) or never runs (also bad) — both break the
        // picker contract.
        let installBlock = "install.installsAppBundle"
        #expect(
            source.contains(installBlock),
            "provisionBundleForCreate must branch on `install.installsAppBundle` to honour the three-way Guest Tools picker."
        )
        #expect(
            source.contains("DiskInjector.installGuestTools"),
            "provisionBundleForCreate must call `DiskInjector.installGuestTools` for VMs created with `.installed`."
        )
    }
}
