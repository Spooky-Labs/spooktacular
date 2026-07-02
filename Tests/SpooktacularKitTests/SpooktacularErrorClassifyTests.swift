import Foundation
import Testing

/// Regression test for task #71: `SpooktacularError.classify`
/// must preserve a typed `LocalizedError`'s own
/// `recoverySuggestion` instead of flattening every unknown
/// error into `.internalError`'s generic "file a bug" text.
///
/// Concrete symptom that motivated the fix: when a user
/// clicked *Install Guest Tools* on a VM whose Data volume
/// was already FileVault-locked,
/// `DiskInjectorError.guestVolumeEncrypted` was thrown with a
/// rich description + actionable recovery ("delete and
/// recreate the VM so install happens before Setup
/// Assistant"). `classify` was collapsing it into
/// `.internalError(reason: error.localizedDescription)`,
/// which discards `recoverySuggestion` — so the alert
/// rendered "File a bug report…" under a description that
/// explicitly told the user what to do.
///
/// `SpooktacularError` lives in the `Spooktacular` app
/// target (not reachable from this SwiftPM test bundle), so
/// we assert at source level — the same pattern
/// `GuestToolsInstalledCleanupTests` and
/// `GuestToolsProvisioningGateTests` use.
@Suite("SpooktacularError.classify preserves typed recovery suggestions")
struct SpooktacularErrorClassifyTests {

    private func appStateSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appStateFile = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("Spooktacular")
            .appendingPathComponent("AppState.swift")
        return try String(contentsOf: appStateFile, encoding: .utf8)
    }

    @Test("detailed case exists on SpooktacularError")
    func detailedCaseExists() throws {
        let source = try appStateSource()
        #expect(
            source.contains("case detailed(description: String, recovery: String)"),
            "SpooktacularError must carry a `.detailed(description:recovery:)` case so typed LocalizedError recovery suggestions survive classification. Without it, useful next-step text (e.g. `DiskInjectorError.guestVolumeEncrypted`'s 'delete and recreate the VM') is overwritten by the generic `.internalError` 'file a bug' message."
        )
    }

    @Test("classify consults LocalizedError before falling back to internalError")
    func classifyConsultsLocalizedError() throws {
        let source = try appStateSource()
        // The fixed shape: before the final `.internalError`
        // fallback, classify does an `as? LocalizedError`
        // cast and returns `.detailed(...)` when both
        // description and recovery are populated. Assert the
        // cast is present.
        #expect(
            source.contains("as? LocalizedError"),
            "classify must attempt `as? LocalizedError` so errors that already carry their own description + recovery (e.g. DiskInjectorError) surface verbatim instead of being flattened into `.internalError`."
        )
        #expect(
            source.contains(".detailed(description:"),
            "classify must construct `.detailed(description:recovery:)` when a LocalizedError provides both fields. Missing this call is the anti-pattern that caused task #71."
        )
    }

    @Test("classify guards against empty description/recovery strings")
    func classifyGuardsEmptyStrings() throws {
        let source = try appStateSource()
        // NSErrors bridge to LocalizedError with empty
        // default recoverySuggestion. Without an !isEmpty
        // guard, classify would wrongly return .detailed
        // with an empty recovery — worse than falling
        // through to .internalError, since the user would
        // see a blank recovery line.
        #expect(
            source.contains("!description.isEmpty") || source.contains("description.isEmpty == false"),
            "classify must reject empty `errorDescription`s before returning `.detailed` — the Swift-bridged NSError default returns empty strings, not nil, so a bare nil-check isn't enough."
        )
        #expect(
            source.contains("!recovery.isEmpty") || source.contains("recovery.isEmpty == false"),
            "classify must reject empty `recoverySuggestion`s before returning `.detailed` — see the parallel description guard."
        )
    }
}

/// Regression test for task #71 part two: the
/// `DiskInjectorError.guestVolumeEncrypted` recovery text
/// must guide the user to *delete + recreate the VM* — the
/// only viable path once FileVault has locked the Data
/// volume. The pre-fix text told the user to run
/// `curl -sL https://example.com/spooktacular-agent | sudo bash`
/// inside the VM, a legacy instruction from the
/// `spooktacular-agent` binary days (pre-Guest-Tools).
/// That command doesn't even exist anymore.
@Suite("DiskInjectorError.guestVolumeEncrypted has current recovery text")
struct DiskInjectorGuestVolumeEncryptedTextTests {

    private func diskInjectorSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SpooktacularInfrastructureApple")
            .appendingPathComponent("DiskInjector.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("recovery tells user to delete and recreate the VM")
    func recoveryMentionsRecreate() throws {
        let source = try diskInjectorSource()
        #expect(
            source.contains("Delete this VM and create a new one"),
            "guestVolumeEncrypted's recoverySuggestion must guide the user to delete + recreate the VM (the only path once FileVault locks the Data volume). Without this exact guidance the user is stuck — the GUI button just keeps failing with the same opaque error."
        )
    }

    @Test("recovery no longer references the removed spooktacular-agent curl bootstrap")
    func recoveryDoesNotReferenceLegacyAgent() throws {
        let source = try diskInjectorSource()
        #expect(
            !source.contains("curl -sL https://example.com/spooktacular-agent"),
            "Detected the legacy `curl -sL https://example.com/spooktacular-agent | sudo bash` instruction. That endpoint never existed and the `spooktacular-agent` executable no longer exists. Must point at delete+recreate instead."
        )
    }
}
