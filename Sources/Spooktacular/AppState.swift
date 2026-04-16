import SwiftUI
import os
@preconcurrency import Virtualization
import SpooktacularKit

/// The shared application state for Spooktacular.
///
/// `AppState` tracks all known VM bundles, running VM instances,
/// selected state, and user-facing errors. Views observe it via
/// the SwiftUI `@Environment`.
///
/// All error-producing operations surface errors through
/// ``errorMessage`` and ``errorPresented``, which drives a
/// centralized alert in the root view. This ensures the same
/// error presentation behavior across all user interactions.
@Observable
@MainActor
final class AppState {

    // MARK: - VM Management

    /// All known VM bundles, keyed by name.
    var vms: [String: VirtualMachineBundle] = [:]

    /// The currently selected VM name in the sidebar.
    var selectedVM: String?

    /// Running VM instances, keyed by name.
    var runningVMs: [String: VirtualMachine] = [:]

    /// Guest agent clients for running VMs.
    var agentClients: [String: GuestAgentClient] = [:]

    /// Names of VMs whose dedicated workspace window is currently
    /// open. Populated by ``workspaceDidOpen(_:)`` /
    /// ``workspaceDidClose(_:)`` from `WorkspaceWindow`.
    var openWorkspaceWindows: Set<String> = []

    /// Name of the workspace whose window is currently key (front-
    /// most). `nil` when the library or another non-workspace scene
    /// holds focus. Drives ``workspaceIconCoordinator``.
    var focusedWorkspace: String? {
        didSet {
            guard oldValue != focusedWorkspace else { return }
            let spec = focusedWorkspace.flatMap { vms[$0]?.metadata.iconSpec }
            workspaceIconCoordinator.focusChanged(to: spec)
        }
    }

    /// Swaps the Dock tile to reflect the focused workspace.
    let workspaceIconCoordinator = WorkspaceIconCoordinator()

    /// Per-workspace port monitors. Lazily instantiated on first
    /// access so VMs that never open a port panel don't incur the
    /// polling cost.
    private var portMonitors: [String: PortForwardingMonitor] = [:]

    /// The shared clipboard bridge — handles sync between the host
    /// pasteboard and the focused workspace.
    let clipboardBridge = ClipboardBridge()

    /// Macos notification poster for VM lifecycle transitions.
    let notifications = VMNotifications()

    /// Whether the ⌘K command palette is currently presented.
    var showCommandPalette: Bool = false

    /// Returns (or creates) the port monitor for a workspace.
    ///
    /// Wires the monitor to the guest agent once per workspace.
    /// Callers should treat the returned value as a stable,
    /// observable model for SwiftUI bindings.
    func portMonitor(for name: String) -> PortForwardingMonitor {
        if let existing = portMonitors[name] {
            return existing
        }
        let monitor = PortForwardingMonitor()
        portMonitors[name] = monitor
        if let client = agentClients[name], let bundle = vms[name] {
            monitor.start(client: client, macAddress: bundle.spec.macAddress)
        }
        return monitor
    }

    // MARK: - Error Handling

    /// A user-facing error message for the centralized alert.
    var errorMessage: String?

    /// Whether the error alert is presented.
    var errorPresented: Bool = false

    // MARK: - Sheet Presentation

    /// Whether the "Create VM" sheet is showing.
    var showCreateSheet = false

    /// Whether the "Add Image" sheet is showing.
    var showAddImage = false

    // MARK: - Image Library

    /// The local cache of VM images (IPSWs + OCI).
    let imageLibrary = ImageLibrary(
        directory: SpooktacularPaths.root
            .appendingPathComponent("images")
    )

    // MARK: - Paths

    /// VM bundles directory: `~/.spooktacular/vms/`.
    var vmsDirectory: URL { SpooktacularPaths.vms }

    /// IPSW cache directory: `~/.spooktacular/cache/ipsw/`.
    var ipswCacheDirectory: URL { SpooktacularPaths.ipswCache }

    // MARK: - Lifecycle

    /// Scans the VM directory, loads all bundles, and refreshes
    /// the image library.
    func loadVMs() {
        imageLibrary.load()

        do {
            try SpooktacularPaths.ensureDirectories()

            let contents = try FileManager.default.contentsOfDirectory(
                at: vmsDirectory,
                includingPropertiesForKeys: nil
            )

            var loaded: [String: VirtualMachineBundle] = [:]
            for url in contents where url.pathExtension == "vm" {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let bundle = try VirtualMachineBundle.load(from: url)
                    loaded[name] = bundle
                } catch {
                    Log.vm.error("Failed to load bundle '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                }
            }
            vms = loaded
        } catch {
            presentError(error)
        }
    }

    /// Whether a VM is currently running.
    func isRunning(_ name: String) -> Bool {
        runningVMs[name] != nil
    }

    /// Starts a VM by name.
    func startVM(_ name: String) async {
        guard let bundle = vms[name], runningVMs[name] == nil else { return }

        do {
            let vm = try VirtualMachine(bundle: bundle)
            try await vm.start()
            runningVMs[name] = vm

            if let socketDevice = vm.vzVM?.socketDevices.first as? VZVirtioSocketDevice {
                agentClients[name] = GuestAgentClient(socketDevice: socketDevice)
            }

            AccessibilityNotification.Announcement(
                "Virtual machine \(name) started"
            ).post()
            notifications.notifyStarted(name)
        } catch {
            notifications.notifyFailed(name, error: error.localizedDescription)
            presentError(error)
        }
    }

    /// Stops a VM by name.
    func stopVM(_ name: String) async {
        guard let vm = runningVMs[name] else { return }

        do {
            try await vm.stop(graceful: false)
            runningVMs.removeValue(forKey: name)
            agentClients.removeValue(forKey: name)

            AccessibilityNotification.Announcement(
                "Virtual machine \(name) stopped"
            ).post()
            notifications.notifyStopped(name)
        } catch {
            presentError(error)
        }
    }

    /// Deletes a VM by name, stopping it first if running.
    func deleteVM(_ name: String) {
        Task {
            do {
                if let vm = runningVMs.removeValue(forKey: name) {
                    agentClients.removeValue(forKey: name)
                    Log.vm.info("Stopping running VM '\(name, privacy: .public)' before deletion")
                    try await vm.stop(graceful: false)
                }
                if let bundle = vms.removeValue(forKey: name) {
                    try FileManager.default.removeItem(at: bundle.url)
                }
                if selectedVM == name {
                    selectedVM = nil
                }

                AccessibilityNotification.Announcement(
                    "Virtual machine \(name) deleted"
                ).post()
            } catch {
                presentError(error)
            }
        }
    }

    /// Clones a VM.
    func cloneVM(_ source: String, to destination: String) {
        do {
            guard let sourceBundle = vms[source] else { return }
            let destinationURL = SpooktacularPaths.bundleURL(for: destination)
            let clone = try CloneManager.clone(source: sourceBundle, to: destinationURL)
            vms[destination] = clone

            AccessibilityNotification.Announcement(
                "Virtual machine \(source) cloned to \(destination)"
            ).post()
        } catch {
            presentError(error)
        }
    }

    // MARK: - Workspace Window Lifecycle

    /// Called by `WorkspaceWindow` when it first appears.
    ///
    /// Tracks the open window so the library can show a "focused"
    /// indicator and so quit can close workspaces gracefully.
    func workspaceDidOpen(_ name: String) async {
        openWorkspaceWindows.insert(name)
    }

    /// Called by `WorkspaceWindow` when it disappears (user closed
    /// the window or app quit).
    func workspaceDidClose(_ name: String) {
        openWorkspaceWindows.remove(name)
        if focusedWorkspace == name {
            focusedWorkspace = nil
        }
    }

    // MARK: - Shutdown

    /// Stops all running VMs on application termination.
    ///
    /// Each VM gets a 2-second window to stop. If a VM hangs,
    /// the timeout expires and the app continues quitting so the
    /// user is never stuck waiting.
    func stopAllRunningVMs() {
        for (name, vm) in runningVMs {
            Task { @MainActor in
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            try await vm.stop(graceful: false)
                        }
                        group.addTask {
                            try await Task.sleep(for: .seconds(2))
                            throw CancellationError()
                        }
                        // Wait for whichever finishes first, cancel the other.
                        _ = try await group.next()
                        group.cancelAll()
                    }
                    Log.vm.info("Stopped VM '\(name, privacy: .public)' on quit")
                } catch {
                    Log.vm.error("Failed to stop VM '\(name, privacy: .public)' on quit: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        runningVMs.removeAll()
        agentClients.removeAll()
    }

    // MARK: - Private

    /// Surfaces an error to the user through the centralized alert.
    private func presentError(_ error: Error) {
        Log.ui.error("Presenting error to user: \(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
        errorPresented = true
    }
}
