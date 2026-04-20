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

    /// Per-VM streaming host-API servers. Each running VM
    /// publishes live events (metrics, lifecycle, ports) onto a
    /// Unix-domain socket at
    /// `~/Library/Application Support/Spooktacular/api/<vm>.sock`,
    /// so external automation (`curl --unix-socket`, Python,
    /// shell pipelines, dashboards) can subscribe without the
    /// CLI+vsock round-trip overhead that request/response APIs
    /// pay per sample. Bound to the VM's lifetime: created on
    /// `startVM`, torn down on `stopVM`.
    private var streamingServers: [String: VMStreamingServer] = [:]

    /// Per-VM publisher Tasks that pump events from their
    /// source (guest-agent stream, VM state stream, port
    /// monitor) onto the streaming server. Cancelled on
    /// `stopVM` so publishers don't outlive the server they
    /// push to.
    private var publisherTasks: [String: [Task<Void, Never>]] = [:]

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

    /// Imports a portable `.vm` bundle into the local VM
    /// directory, wiring it into the library as if the user had
    /// created it locally.
    ///
    /// Invoked from three places:
    ///
    /// 1. **SwiftUI `.onOpenURL`** — when Finder sends a
    ///    double-clicked or dropped `.vm` bundle to the app.
    ///    Apple's UTI / `CFBundleDocumentTypes` plumbing routes
    ///    the URL here via the Info.plist export of
    ///    `com.spookylabs.spooktacular.vm-bundle`.
    /// 2. **`spooktacular bundle import`** — the CLI uses the
    ///    same `BundleImporter` primitive underneath.
    /// 3. **Drag-and-drop onto the sidebar** — future Track B
    ///    polish; the same entry point.
    ///
    /// Copy semantics: the source bundle is **cloned** via
    /// APFS `clonefile(2)` (through `FileManager.copyItem`) so
    /// importing a 64 GB VM from a thumb drive into `~/.spooktacular/vms/`
    /// completes in milliseconds when the source is already on
    /// an APFS volume. On cross-volume imports (USB / SMB),
    /// FileManager falls back to a full read+write — same as
    /// Finder's drag behavior.
    ///
    /// Machine identifier + MAC address are **regenerated** on
    /// import. The bundle's `machine-identifier.bin` and
    /// `spec.macAddress` are unique to the host that originally
    /// created them; two running copies sharing either would
    /// collide on the host network and in Apple's VZ hardware
    /// identification. The regeneration matches `CloneManager`'s
    /// behaviour so imported and cloned bundles are
    /// indistinguishable downstream.
    func importBundle(from sourceURL: URL) async {
        do {
            let bundle = try BundleImporter.import(
                sourceURL: sourceURL,
                intoDirectory: vmsDirectory
            )
            loadVMs()
            selectedVM = bundle.url.deletingPathExtension().lastPathComponent
            AccessibilityNotification.Announcement(
                "Imported virtual machine \(selectedVM ?? "")"
            ).post()
        } catch {
            presentError(error)
        }
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
            // `startOrResume` transparently restores from a saved-
            // state file when one exists (the "close the laptop"
            // workflow from Suspend), falling back to a cold boot
            // if restore fails or when booting into Recovery.
            try await vm.startOrResume(startUpFromMacOSRecovery: recovery)
            runningVMs[name] = vm

            if let socketDevice = vm.vzVM?.socketDevices.first as? VZVirtioSocketDevice {
                agentClients[name] = GuestAgentClient(socketDevice: socketDevice)
            }

            // Instantiate the Apple-native event listener
            // (`VZVirtioSocketListener` on port 9469) **eagerly**
            // at VM start — not lazily on first detail-view open.
            // The guest agent dials in as soon as its systemd /
            // launchd unit runs, often long before the user
            // navigates to the VM's detail view. If the listener
            // isn't registered yet, the guest gets connection-
            // refused and has to wait for its reconnect cycle,
            // delaying the first stats frame by 2–4 seconds.
            // Eager creation closes that race.
            _ = vm.agentEventListener()

            // Start the streaming host-API server and kick off
            // the domain publishers that feed it. Failures here
            // are non-fatal — the VM itself still boots cleanly
            // and the GUI's in-process Swift paths (chart model,
            // port monitor) continue to work. Only the external
            // UDS surface is affected.
            await startStreamingServices(for: name, vm: vm)

            AccessibilityNotification.Announcement(
                "Virtual machine \(name) started"
            ).post()
            notifications.notifyStarted(name)
        } catch {
            notifications.notifyFailed(name, error: error.localizedDescription)
            presentError(error)
        }
    }

    /// Boots the per-VM ``VMStreamingServer`` and spawns the
    /// publisher tasks that feed its topic bus:
    ///
    /// - **`.metrics`** — one frame per sample the guest agent
    ///   emits on `/api/v1/stats/stream` (~1 Hz). `GuestStatsResponse`
    ///   is mapped 1:1 to ``VMMetricsSnapshot``.
    /// - **`.lifecycle`** — one frame per VM state transition
    ///   published on `VirtualMachine.stateStream`.
    /// - **`.ports`** — fed later from the existing
    ///   ``PortForwardingMonitor``; placeholder until the
    ///   monitor exposes an async stream (follow-up polish).
    ///
    /// Each publisher runs in its own `Task` so failure of one
    /// (e.g., an older guest agent that doesn't speak
    /// `/api/v1/stats/stream`) doesn't take down the others.
    /// Publisher loops exit cleanly when
    /// ``stopStreamingServices(for:)`` cancels them.
    private func startStreamingServices(for name: String, vm: VirtualMachine) async {
        do {
            let socketURL = try SpooktacularPaths.apiSocketURL(for: name)
            let server = VMStreamingServer(vmName: name, socketURL: socketURL)
            try await server.start()
            streamingServers[name] = server

            var tasks: [Task<Void, Never>] = []

            // Unified guest event publisher. One vsock
            // connection carries `.stats`, `.ports`, and
            // `.appsFrontmost` frames; we demux and republish
            // each onto the matching streaming-server topic.
            // Replaces the previous `statsStream()`-only path
            // so external automation subscribing to the UDS
            // `ports` topic gets push events instead of the
            // polling fallback.
            // Re-publish the Apple-native listener's events onto
            // the external VMStreamingServer topics. Replaces the
            // prior `client.eventStream()` HTTP path so UDS
            // subscribers see stats + ports from the same source
            // the GUI chart consumes.
            if let listener = vm.agentEventListener() {
                tasks.append(Task { [weak server] in
                    do {
                        for try await event in listener.events() {
                            guard !Task.isCancelled else { return }
                            switch event {
                            case .stats(let stats):
                                let snapshot = VMMetricsSnapshot(
                                    at: Date(),
                                    cpuUsage: stats.cpuUsage,
                                    memoryUsedBytes: stats.memoryUsedBytes,
                                    memoryTotalBytes: stats.memoryTotalBytes,
                                    loadAverage1m: stats.loadAverage1m,
                                    processCount: stats.processCount,
                                    uptime: stats.uptime
                                )
                                await server?.publish(topic: .metrics, payload: snapshot)
                            case .ports(let entries):
                                let snapshot = VMPortsSnapshot(
                                    at: Date(),
                                    ports: entries.map {
                                        .init(port: $0.port, processName: $0.processName)
                                    }
                                )
                                await server?.publish(topic: .ports, payload: snapshot)
                            case .appsFrontmost:
                                // No VMStreamingProtocol topic
                                // for frontmost yet — reserved
                                // for Track J dock-icon mirroring.
                                break
                            }
                        }
                    } catch {
                        // Older agents without
                        // `/api/v1/events/stream` terminate with
                        // a 404-equivalent. Silent no-op; other
                        // topics continue.
                    }
                })
            }

            // Lifecycle publisher — each VM state transition
            // becomes one frame on `.lifecycle`.
            let lifecycleStream = vm.stateStream
            tasks.append(Task { [weak server] in
                for await state in lifecycleStream {
                    guard !Task.isCancelled else { return }
                    let event = VMLifecycleEvent(
                        at: Date(),
                        state: state.rawValue
                    )
                    await server?.publish(topic: .lifecycle, payload: event)
                }
            })

            publisherTasks[name] = tasks
        } catch {
            Log.vm.warning(
                "Streaming server failed to start for \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Symmetric teardown for ``startStreamingServices(for:vm:)``.
    private func stopStreamingServices(for name: String) async {
        if let tasks = publisherTasks.removeValue(forKey: name) {
            for task in tasks { task.cancel() }
        }
        if let server = streamingServers.removeValue(forKey: name) {
            await server.stop()
        }
    }

    /// Suspends a running VM to disk and shuts it down.
    ///
    /// Mirrors ``stopVM(_:)`` but instead of a clean shutdown
    /// writes a `SavedState.vzstate` file into the bundle. A
    /// later ``startVM(_:)`` transparently restores from that
    /// file — the user picks up with every app open, every
    /// document unsaved, exactly where they left off.
    ///
    /// Same re-entry guard as `stopVM`: rapid Suspend-button
    /// taps collapse to a single suspend.
    func suspendVM(_ name: String) async {
        guard let vm = runningVMs[name] else { return }
        guard !transitioningVMs.contains(name) else { return }

        transitioningVMs.insert(name)
        defer { transitioningVMs.remove(name) }

        do {
            try await vm.suspend()
            runningVMs.removeValue(forKey: name)
            agentClients.removeValue(forKey: name)
            await stopStreamingServices(for: name)

            AccessibilityNotification.Announcement(
                "Virtual machine \(name) suspended"
            ).post()
            notifications.notifyStopped(name)
        } catch {
            presentError(error)
        }
    }

    /// Discards the suspend file for `name` without starting the
    /// VM. Equivalent to `spook discard-suspend` on the CLI —
    /// the next `startVM` is guaranteed to cold-boot.
    ///
    /// Synchronous because the VM is known to be stopped (or
    /// else this wouldn't be meaningful — you'd use `suspend`
    /// or `stop`). Returns `true` when a file was removed so the
    /// UI can surface "already cold" without a follow-up query.
    @discardableResult
    func discardSuspend(_ name: String) -> Bool {
        guard let bundle = vms[name] else { return false }
        let url = bundle.savedStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    /// `true` when the VM's bundle carries a `SavedState.vzstate`
    /// file, meaning the next `startVM` will resume. Drives the
    /// Resume-vs-Start label in the GUI.
    func isSuspended(_ name: String) -> Bool {
        guard let bundle = vms[name] else { return false }
        return bundle.hasSavedState
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
            await stopStreamingServices(for: name)

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
                    await stopStreamingServices(for: name)
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
