import SwiftUI
import os
@preconcurrency import Virtualization
import SpooktacularKit

// MARK: - SpooktacularError

/// User-facing errors categorized by recovery path.
///
/// Every case carries a ``localizedDescription`` explaining
/// *what* happened plus a ``suggestedAction`` explaining *how to
/// fix it*. The SwiftUI alert surfaces both so users are never
/// stuck on a failure without a next step — matching Apple HIG
/// guidance that destructive or failed operations should always
/// offer a path forward.
///
/// ## Mapping
///
/// | Case | Example |
/// |------|---------|
/// | ``diskFull`` | Sparse disk expansion exceeded volume capacity |
/// | ``networkTimeout`` | IPSW CDN request exceeded 120s |
/// | ``quotaExceeded`` | Tenant limit reached |
/// | ``invalidVMName`` | Name contains `/` or is empty |
/// | ``vmNotFound`` | Bundle removed while window was open |
/// | ``permissionDenied`` | Missing sandbox entitlement |
/// | ``internalError`` | Unexpected; catch-all |
enum SpooktacularError: LocalizedError, Equatable, Sendable {
    case diskFull(requested: UInt64, available: UInt64)
    case networkTimeout(service: String)
    case quotaExceeded(current: Int, max: Int)
    case invalidVMName(reason: String)
    case vmNotFound(name: String)
    case permissionDenied(what: String)
    case internalError(reason: String)

    /// A human-readable explanation of what went wrong.
    var errorDescription: String? {
        switch self {
        case .diskFull(let requested, let available):
            let r = ByteCountFormatter.string(fromByteCount: Int64(requested), countStyle: .file)
            let a = ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .file)
            return "Disk full — need \(r), have \(a)."
        case .networkTimeout(let service):
            return "\(service) did not respond in time."
        case .quotaExceeded(let current, let max):
            return "Quota exceeded — \(current) of \(max) VMs in use."
        case .invalidVMName(let reason):
            return "Invalid VM name: \(reason)"
        case .vmNotFound(let name):
            return "No virtual machine named '\(name)'."
        case .permissionDenied(let what):
            return "Permission denied: \(what)"
        case .internalError(let reason):
            return "Internal error: \(reason)"
        }
    }

    /// A short action the user can take to recover, rendered
    /// beneath the alert message.
    var suggestedAction: String {
        switch self {
        case .diskFull:
            return "Free disk space on your host volume, or choose a smaller disk size, and retry."
        case .networkTimeout:
            return "Check your internet connection and retry. Downloads resume from where they left off."
        case .quotaExceeded:
            return "Delete an unused VM or request a higher quota from your administrator."
        case .invalidVMName:
            return "Use only letters, digits, dashes, or underscores. 1-64 characters."
        case .vmNotFound:
            return "Run spook list to see available virtual machines."
        case .permissionDenied:
            return "Grant access in System Settings → Privacy & Security, then retry."
        case .internalError:
            return "File a bug report at github.com/Spooky-Labs/spooktacular/issues with the error text."
        }
    }

    /// `LocalizedError.recoverySuggestion` so the SwiftUI
    /// `Alert.message` format string gets the suggested action
    /// by default.
    var recoverySuggestion: String? { suggestedAction }

    /// Classifies a raw `Error` into a ``SpooktacularError``
    /// so AppState's centralized alert can present a consistent
    /// message + action regardless of which subsystem surfaced it.
    static func classify(_ error: Error) -> SpooktacularError {
        if let already = error as? SpooktacularError { return already }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError {
            return .diskFull(requested: 0, available: 0)
        }
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
            return .networkTimeout(service: "Network")
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError {
            return .permissionDenied(what: ns.localizedDescription)
        }
        return .internalError(reason: error.localizedDescription)
    }
}

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

    // MARK: - Lifecycle Transitions

    /// Names of VMs currently transitioning (starting / stopping /
    /// cloning). Observed by ``SpooktacularApp`` to swap the menu-
    /// bar icon for a busy indicator.
    var transitioningVMs: Set<String> = []

    /// Whether any VM is currently mid-transition.
    var isAnyVMTransitioning: Bool { !transitioningVMs.isEmpty }

    // MARK: - Error Handling

    /// A user-facing error message for the centralized alert.
    var errorMessage: String?

    /// A user-facing suggested next step, rendered as a second
    /// line beneath ``errorMessage`` in the alert. Populated
    /// from ``SpooktacularError/suggestedAction``.
    var errorSuggestedAction: String?

    /// Whether the error alert is presented.
    var errorPresented: Bool = false

    // MARK: - Sheet Presentation

    /// Whether the "Create VM" sheet is showing.
    var showCreateSheet = false

    /// If non-nil when the Create VM sheet opens, pre-seeds the
    /// sheet's IPSW source to `.local` with this path. Set by
    /// "Create VM from image" in the image detail view so the
    /// sheet picks up the image the user just selected instead
    /// of defaulting to Apple's latest download.
    var pendingCreateIpswPath: String?

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
    ///
    /// Marks the VM as transitioning for the duration of the start
    /// sequence so the menu-bar icon switches to its busy variant.
    ///
    /// - Parameter recovery: When `true`, boots the guest into
    ///   macOS Recovery via
    ///   `VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery`.
    ///   Useful for filesystem repair, Startup Security Utility,
    ///   or reinstalling the OS. Defaults to `false`.
    func startVM(_ name: String, recovery: Bool = false) async {
        guard let bundle = vms[name], runningVMs[name] == nil else { return }
        guard !transitioningVMs.contains(name) else { return }

        transitioningVMs.insert(name)
        defer { transitioningVMs.remove(name) }

        do {
            let vm = try VirtualMachine(bundle: bundle)
            try await vm.start(startUpFromMacOSRecovery: recovery)
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
    ///
    /// Marks the VM as transitioning for the duration of the stop
    /// sequence so the menu-bar icon switches to its busy variant.
    ///
    /// Guards against re-entry: if a stop is already in flight for
    /// this VM (rapid-tap the Stop button, simultaneous context-menu
    /// Stop, etc.), subsequent calls are a no-op. Without the guard
    /// VZ raises `Invalid state transition. Transition from state
    /// "stopping" to state "stopping" is invalid` and the error
    /// alert fires every time the user clicks again.
    func stopVM(_ name: String) async {
        guard let vm = runningVMs[name] else { return }
        guard !transitioningVMs.contains(name) else { return }

        transitioningVMs.insert(name)
        defer { transitioningVMs.remove(name) }

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
    ///
    /// Marks the destination name as transitioning for the
    /// duration so the menu-bar icon reflects that a clone is
    /// in progress.
    func cloneVM(_ source: String, to destination: String) {
        do {
            guard let sourceBundle = vms[source] else { return }
            transitioningVMs.insert(destination)
            defer { transitioningVMs.remove(destination) }
            let destinationURL = try SpooktacularPaths.bundleURL(for: destination)
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

    /// `@AppStorage`-compatible key for persisted open workspace
    /// names. Consumed at launch by ``ContentView`` to restore
    /// previously open windows.
    static let openWorkspacesDefaultsKey = "openWorkspaces"

    /// Called by `WorkspaceWindow` when it first appears.
    ///
    /// Tracks the open window so the library can show a "focused"
    /// indicator and so quit can close workspaces gracefully.
    /// Also persists the set to UserDefaults for next-launch
    /// window restoration.
    func workspaceDidOpen(_ name: String) async {
        openWorkspaceWindows.insert(name)
        persistOpenWorkspaces()
    }

    /// Called by `WorkspaceWindow` when it disappears (user closed
    /// the window or app quit).
    func workspaceDidClose(_ name: String) {
        openWorkspaceWindows.remove(name)
        if focusedWorkspace == name {
            focusedWorkspace = nil
        }
        persistOpenWorkspaces()
    }

    /// Reads the set of previously-open workspace names from
    /// UserDefaults, filtering out any VMs that no longer exist
    /// on disk. Called once at launch by ``ContentView``.
    func restorableWorkspaceNames() -> [String] {
        guard let data = UserDefaults.standard.data(forKey: Self.openWorkspacesDefaultsKey),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        // Filter against the on-disk VM list so deleted VMs are
        // silently skipped.
        return decoded.filter { vms[$0] != nil }
    }

    /// Writes the current open-windows set to UserDefaults as JSON.
    private func persistOpenWorkspaces() {
        let names = Array(openWorkspaceWindows).sorted()
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: Self.openWorkspacesDefaultsKey)
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

    // MARK: - Error Presentation

    /// Surfaces an error to the user through the centralized alert.
    ///
    /// Routes every error through ``SpooktacularError/classify(_:)``
    /// so the alert shows a consistent "what + how to recover"
    /// pair regardless of which subsystem threw.
    func presentError(_ error: Error) {
        let categorized = SpooktacularError.classify(error)
        Log.ui.error("Presenting error to user: \(categorized.errorDescription ?? "unknown", privacy: .public)")
        errorMessage = categorized.errorDescription
        errorSuggestedAction = categorized.suggestedAction
        errorPresented = true
    }
}
