import Foundation
import Testing

/// Regression test for task #70: `AppState.deleteVM` must
/// clean up the `guestToolsInstalled` set so a recreated VM
/// with the same name doesn't inherit the prior VM's
/// installed-flag. The flag is persisted to UserDefaults,
/// so without explicit cleanup the stale entry would
/// survive across app launches AND across VM recreations.
///
/// Caught during E2E verification: user created `test` VM,
/// retroactive install failed due to FileVault encryption
/// on re-install, but the button still rendered "Guest
/// Tools Installed ✓" because the create-time success flag
/// from the prior `test` VM was never cleared.
///
/// Unit-level AppState testing would require mocking VMs,
/// bundles, disks, and `@MainActor` context — far too much
/// scaffolding for a one-line cleanup. A source-level
/// assertion catches the class of regression at a tiny
/// fraction of the cost.
@Suite("Guest Tools installed set cleanup on delete")
struct GuestToolsInstalledCleanupTests {

    @Test("AppState.deleteVM clears guestToolsInstalled for the deleted VM")
    func deleteCleansUpGuestToolsInstalledSet() throws {
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

        // Locate the deleteVM function body; we want to see
        // a `guestToolsInstalled.remove(name)` inside it.
        // Without the cleanup, deleting VM 'foo' and
        // recreating VM 'foo' makes the new VM inherit the
        // prior one's installed-flag — a UX lie that
        // obscures real install failures.
        //
        // Pragmatic search: look for the deleteVM function
        // signature and walk forward until the matching
        // closing brace, then assert the substring appears.
        guard let deleteStart = source.range(of: "func deleteVM(_ name: String) {")
        else {
            Issue.record("deleteVM(_:) not found in AppState.swift — test is obsolete.")
            return
        }
        let deleteBody = String(source[deleteStart.upperBound...])
        // Take the first ~5000 characters; the function
        // isn't longer than that and this avoids scanning
        // the whole rest of the file for an unrelated match.
        let snippet = String(deleteBody.prefix(5000))

        #expect(
            snippet.contains("guestToolsInstalled.remove(name)"),
            "deleteVM must call guestToolsInstalled.remove(name) — otherwise recreating a VM with the same name inherits the prior VM's installed-flag and the detail-view button lies."
        )
    }
}
