import SwiftUI
import AppKit
import ServiceManagement
import SpiceClipboardAgent
import os

/// Owns the long-running SPICE clipboard agent Task and
/// surfaces its status into an `@Observable` property for
/// SwiftUI. Registers the app as a login item on first launch
/// (via `SMAppService.mainApp`) so the bridge survives reboots
/// without the user having to re-open the app manually.
///
/// Also drives the Enable / Disable Provisioning menu actions,
/// delegating to ``ProvisionerInstaller`` — the pkg-based
/// installer that replaced the earlier `SMAppService.daemon`
/// path. See ``ProvisionerInstaller`` for the rationale.
///
/// The previous design also ran an HTTP/vsock guest-agent
/// server from inside this controller. That surface was
/// removed — `AF_VSOCK` is not permitted under the App
/// Sandbox (the sandbox grammar gates socket families via
/// `(allow system-socket (socket-domain <N>))` and there's
/// no rule for `socket-domain 40`), and we deliberately
/// keep the sandbox. If host→guest RPC is needed later, the
/// Apple-native path is an un-sandboxed XPC helper (Track J
/// in `plans/dapper-wishing-lake.md`).
@MainActor
@Observable
final class AgentController {

    // MARK: - Observable state

    /// Current SPICE clipboard-agent status. Drives the
    /// menu-bar symbol, tint, and status line.
    var status: SpiceAgentStatus = .notStarted

    /// Whether the app is currently registered as a login item.
    /// Bound by the "Launch at Login" toggle in the menu.
    var launchAtLoginEnabled: Bool {
        didSet {
            guard launchAtLoginEnabled != oldValue else { return }
            Task { await applyLoginItem(enabled: launchAtLoginEnabled) }
        }
    }

    /// Human-readable reason for why the last login-item
    /// register/unregister failed. `nil` when the current state
    /// matches the user's intent.
    var loginItemError: String?

    /// Whether the Spooktacular provisioner LaunchDaemon is
    /// installed in the guest. Mirrors
    /// ``ProvisionerInstaller/isInstalled`` — i.e. presence of
    /// `/Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist`.
    /// Refreshed whenever the menu opens since the user may
    /// have run the pkg's uninstaller while the app was
    /// running.
    ///
    /// When `true`, a host-written `first-boot.sh` in the VM
    /// bundle's `provision/` share runs automatically as root
    /// on next boot. When `false`, the menu offers an "Enable
    /// Provisioning" button that opens the bundled pkg.
    var provisionerInstalled: Bool

    /// Human-readable error from the last install / uninstall
    /// attempt. Cleared on the next successful round-trip.
    /// `nil` for the no-pending-attempt-failed state.
    var provisionerError: String?

    // MARK: - Private state

    private var agentTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        // Seed the toggle state from the live SMAppService
        // status — avoids a flicker if the user previously
        // approved login-at-launch.
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        // Seed the provisioner state from disk. Any later
        // install / uninstall updates `provisionerInstalled`
        // directly.
        provisionerInstalled = Self.isProvisionerInstalledOnDisk()

        start()
    }

    /// Presence of the LaunchDaemon plist on disk — the
    /// single authoritative "is the daemon installed" signal
    /// once the pkg has run. A query `launchctl` gives is
    /// blocked by the sandbox; file existence is not.
    private static func isProvisionerInstalledOnDisk() -> Bool {
        ProvisionerInstaller.isInstalled
    }

    // MARK: - Provisioning

    nonisolated(unsafe) private static let provisioningLogger = Logger(
        subsystem: "com.spooktacular.GuestTools",
        category: "provisioner"
    )

    /// Menu action: opens `Spooktacular Provisioner.pkg` in
    /// Installer.app. The user walks through the installer
    /// wizard, enters their admin password once, and the pkg's
    /// postinstall writes the LaunchDaemon plist + runner with
    /// `root:wheel` ownership and bootstraps the daemon.
    func enableProvisioning() {
        provisionerError = nil
        do {
            try ProvisionerInstaller.install(
                logger: Self.provisioningLogger
            )
            // Presence check happens next time the menu opens
            // (`refreshProvisioningStatus`). Don't flip
            // `provisionerInstalled` optimistically here — the
            // user might cancel the installer wizard without
            // actually installing, and we'd be lying to the UI.
        } catch {
            let description = Self.describe(error)
            Self.provisioningLogger.error(
                "Opening provisioner pkg failed: \(description, privacy: .public)"
            )
            provisionerError = description
        }
    }

    /// Expands an `NSError` into `message [domain code]` so the
    /// UI (and the unified log) shows a more specific error
    /// than `localizedDescription` alone. `nonisolated` so any
    /// actor context can format errors.
    nonisolated private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
    }

    /// Menu action: copies an uninstall command to the user's
    /// clipboard and opens Terminal. Sandbox forbids us from
    /// shelling out with sudo directly, so we hand off to
    /// Terminal the same way install hands off to
    /// Installer.app — one paste + Return + admin password and
    /// the daemon is gone.
    func disableProvisioning() {
        provisionerError = nil
        do {
            try ProvisionerInstaller.uninstall(
                logger: Self.provisioningLogger
            )
        } catch {
            let description = Self.describe(error)
            Self.provisioningLogger.error(
                "Uninstall command prep failed: \(description, privacy: .public)"
            )
            provisionerError = description
        }
    }

    /// Refreshes `provisionerInstalled` from disk. Called
    /// from the menu content view's `.task` modifier on
    /// appearance — catches the user running the pkg or
    /// removing the daemon manually while Guest Tools was
    /// in the background.
    func refreshProvisioningStatus() {
        provisionerInstalled = Self.isProvisionerInstalledOnDisk()
    }

    // MARK: - Agent lifecycle

    /// Starts the SPICE clipboard bridge. Idempotent — safe
    /// to call multiple times; only the first has effect.
    func start() {
        if agentTask == nil {
            agentTask = Task { [weak self] in
                await self?.runAgent()
            }
        }
    }

    /// Cancels the SPICE agent loop and its status-mirror
    /// task.
    func stop() {
        agentTask?.cancel()
        statusTask?.cancel()
        agentTask = nil
        statusTask = nil
        status = .notStarted
    }

    private func runAgent() async {
        let agent: SpiceClipboardAgent
        do {
            agent = try SpiceClipboardAgent.withDefaultTransport(
                pasteboard: AppKitPasteboardBridge()
            )
        } catch {
            status = .failed(.transportFailed(error))
            return
        }

        // Mirror the actor's status stream into our
        // `@Observable` `status` property so the menu-bar UI
        // reflects handshake / error state. `statusStream` is
        // `nonisolated let` on the agent actor — no `await`
        // needed to read it.
        statusTask = Task { [weak self] in
            for await next in agent.statusStream {
                await MainActor.run {
                    self?.status = next
                }
            }
        }

        await agent.run()
    }

    // MARK: - Login-item registration

    /// Registers (or unregisters) the app as a login item so
    /// it auto-starts at user login. Uses `SMAppService.mainApp`
    /// — the "the whole app IS the login item" variant that
    /// doesn't require a nested helper bundle.
    private func applyLoginItem(enabled: Bool) async {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try await service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // Resync the toggle with the real state — the
            // register may have failed because the user
            // declined the OS permission prompt.
            launchAtLoginEnabled = service.status == .enabled
        }
    }
}
