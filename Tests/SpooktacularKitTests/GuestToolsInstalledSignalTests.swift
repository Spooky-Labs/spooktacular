import Foundation
import Testing

/// Regression test for the host-sampler false-positive bug: within
/// ~1s of starting ANY macOS VM — including one created with Guest
/// Tools explicitly disabled — `AppState.startStreamingServices`'s
/// `events()` subscriber used to treat the first event of any kind
/// (guest-originated OR the synthetic `.stats` frame
/// `HostMetricsSampler` injects once per second, see
/// `AgentEventListener.inject`) as proof Guest Tools were installed
/// and running, self-registering the VM into `guestToolsInstalled`.
///
/// The fix deletes that heuristic outright and gates
/// `guestToolsInstalled` exclusively on the two places a Guest
/// Tools install is actually, verifiably performed:
/// `installGuestTools(_:)` (the manual "Install Guest Tools"
/// button) and `provisionBundleForCreate` (create-time install),
/// both right after `DiskInjector.installGuestTools` returns
/// successfully.
///
/// Like the other `AppState.swift` gate tests, this is a
/// source-level assertion — `AppState` needs a live `@MainActor`
/// app context (VMs, bundles, disks) that's far too much
/// scaffolding to stand up in a unit test for a bookkeeping bug.
@Suite("Guest Tools installed — verifiable signal only")
struct GuestToolsInstalledSignalTests {

    private func readAppStateSource() throws -> String {
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

    @Test("startStreamingServices no longer self-registers guestToolsInstalled from any event")
    func eventsSubscriberDoesNotSelfRegister() throws {
        let source = try readAppStateSource()

        guard let subscriberStart = source.range(of: "for try await event in listener.events() {") else {
            Issue.record("events() subscriber loop not found in AppState.swift — test is obsolete.")
            return
        }
        // The subscriber loop runs until the matching closing
        // brace of `startStreamingServices`; a generous prefix
        // comfortably covers the loop body without needing a
        // brace-matching parser.
        let loopBody = String(source[subscriberStart.upperBound...].prefix(2000))

        #expect(
            !loopBody.contains("guestToolsInstalled.insert"),
            "The events() subscriber must not insert into guestToolsInstalled — it sees both guest-originated frames AND the synthetic host-sampler .stats frame injected once per second for every started VM, so 'any event arrived' is not proof Guest Tools are installed."
        )
    }

    @Test("provisionBundleForCreate marks guestToolsInstalled after a verified DiskInjector.installGuestTools success")
    func createTimeInstallMarksVerifiedSignal() throws {
        let source = try readAppStateSource()

        guard let funcStart = source.range(of: "private func provisionBundleForCreate(") else {
            Issue.record("provisionBundleForCreate(_:) not found in AppState.swift — test is obsolete.")
            return
        }
        let body = String(source[funcStart.upperBound...].prefix(3000))

        #expect(
            body.contains("DiskInjector.installGuestTools"),
            "provisionBundleForCreate must call DiskInjector.installGuestTools for VMs created with Guest Tools install enabled."
        )
        #expect(
            body.contains("guestToolsInstalled.insert(bundle.id.uuidString)"),
            "provisionBundleForCreate must mark guestToolsInstalled — keyed by the bundle's UUID, matching vms's key space — right after DiskInjector.installGuestTools succeeds. Without this, a VM created with Guest Tools enabled has no verified path into guestToolsInstalled at all once the event-based heuristic is removed."
        )
    }

    @Test("installGuestTools(_:) still marks guestToolsInstalled after a verified install")
    func manualInstallMarksVerifiedSignal() throws {
        let source = try readAppStateSource()

        guard let funcStart = source.range(of: "func installGuestTools(_ name: String) {") else {
            Issue.record("installGuestTools(_:) not found in AppState.swift — test is obsolete.")
            return
        }
        let body = String(source[funcStart.upperBound...].prefix(3000))

        #expect(
            body.contains("guestToolsInstalled.insert(name)"),
            "installGuestTools(_:) must mark guestToolsInstalled after DiskInjector.installGuestTools succeeds — the one manual, fully-verified install path."
        )
    }
}
