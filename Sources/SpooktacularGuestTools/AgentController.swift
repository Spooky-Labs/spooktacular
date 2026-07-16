import SwiftUI
import AppKit
import ServiceManagement
import SpiceClipboardAgent

/// Owns the long-running SPICE clipboard agent Task and
/// surfaces its status into an `@Observable` property for
/// SwiftUI. Registers the app as a login item on first launch
/// (via `SMAppService.mainApp`) so the bridge survives reboots
/// without the user having to re-open the app manually.
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

    // MARK: - Private state

    private var agentTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        // Seed the toggle state from the live SMAppService
        // status — avoids a flicker if the user previously
        // approved login-at-launch.
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        start()
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
