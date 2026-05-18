import Testing
import Foundation

/// Regression guard for Phase 2 of the Secure-Enclave migration:
/// destructive CLI commands must route through
/// `AdminPresenceGate.requirePresence` so that malware running
/// as the logged-in user cannot delete or roll back VMs / snapshots
/// without a fresh Touch ID / passcode gesture.
///
/// The test greps each destructive command's source file for
/// `AdminPresenceGate.requirePresence`. A regression that drops
/// the gate silently breaks the threat model but would otherwise
/// be invisible to most downstream tests — the gate's own unit
/// tests verify it works in isolation, not that it's wired into
/// every site that needs it.
///
/// Apple doc citation for the gate's underlying API:
/// https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication
@Suite("Destructive CLI commands invoke the presence gate", .tags(.security))
struct DestructiveCommandPresenceGateTests {

    /// Walks upward from the test bundle to the repo root so the
    /// test works regardless of whether it's run from Xcode, CI,
    /// or `swift test` in any working directory.
    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/SpooktacularKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        // Defensive: if the source layout changes, bail out
        // with a useful error rather than panic.
        while !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Package.swift").path
        ) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return url
    }

    private func sourceContains(
        _ needle: String,
        in relativePath: String
    ) throws -> Bool {
        let url = repoRoot().appendingPathComponent(relativePath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.contains(needle)
    }

    @Test("spook delete gates on AdminPresenceGate")
    func deleteCommandGates() throws {
        let hasGate = try sourceContains(
            "AdminPresenceGate.requirePresence",
            in: "Sources/spooktacular-cli/Commands/Delete.swift"
        )
        #expect(
            hasGate,
            "Delete.swift must call AdminPresenceGate.requirePresence — dropping the presence gate re-opens the malware-as-logged-in-user VM-wipe path (Phase 2)."
        )
    }

    @Test("spook snapshot delete + restore gate on AdminPresenceGate")
    func snapshotCommandsGate() throws {
        // Delete + Restore = 2 expected call sites. Save + List
        // do not gate — save is non-destructive, list is read-only.
        let url = repoRoot().appendingPathComponent("Sources/spooktacular-cli/Commands/Snapshot.swift")
        let contents = try String(contentsOf: url, encoding: .utf8)
        let count = contents
            .components(separatedBy: "AdminPresenceGate.requirePresence")
            .count - 1
        #expect(
            count >= 2,
            "Snapshot.swift must call AdminPresenceGate.requirePresence at least twice (snapshot delete + snapshot restore)."
        )
    }
}
