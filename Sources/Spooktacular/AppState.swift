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
    /// Preserves a typed `LocalizedError`'s own description +
    /// recovery verbatim so subsystems like ``DiskInjectorError``
    /// can surface an actionable next step (e.g. "delete and
    /// recreate the VM") instead of being flattened into the
    /// generic ``internalError``'s "file a bug" suggestion.
    case detailed(description: String, recovery: String)

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
        case .detailed(let description, _):
            return description
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
        case .detailed(_, let recovery):
            return recovery
        }
    }

    /// `LocalizedError.recoverySuggestion` so the SwiftUI
    /// `Alert.message` format string gets the suggested action
    /// by default.
    var recoverySuggestion: String? { suggestedAction }

    /// Classifies a raw `Error` into a ``SpooktacularError``
    /// so AppState's centralized alert can present a consistent
    /// message + action regardless of which subsystem surfaced it.
    ///
    /// Preserves typed ``LocalizedError`` descriptions *and*
    /// recovery suggestions (via the ``detailed`` case) so
    /// subsystem errors like ``DiskInjectorError.guestVolumeEncrypted``
    /// keep their actionable next step instead of collapsing
    /// into the generic "file a bug" text.
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
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           let recovery = localized.recoverySuggestion,
           !description.isEmpty,
           !recovery.isEmpty {
            return .detailed(description: description, recovery: recovery)
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

    /// All known VM bundles, keyed by the bundle's UUID string —
    /// matching the on-disk `<uuid>.vm` directory basename
    /// (``VirtualMachineBundle/id``). This is NOT the display
    /// name: two VMs may share a display name (see
    /// ``VirtualMachineBundle/displayName``'s doc comment), so a
    /// display name is never a safe dictionary key.
    ///
    /// Every other per-VM dictionary in this class
    /// (`runningVMs`, `transitioningVMs`, `graphicsViews`,
    /// `guestToolsInstalled`, `selectedVM`, `clipboardStatuses`,
    /// `openWorkspaceWindows`, `focusedWorkspace`, …) shares this
    /// same key space. Any code path that only has a display name
    /// — a freshly-typed Clone destination, a runner's
    /// display name before its bundle key is threaded through —
    /// must resolve to the matching `vms` key first, via
    /// `Dictionary.key(forDisplayName:)`, before touching any of
    /// those dictionaries. `pendingCreations` is the one
    /// deliberate exception: it's keyed by display name because a
    /// creation in flight has no bundle (and therefore no UUID)
    /// yet.
    var vms: [String: VirtualMachineBundle] = [:]

    /// The currently selected VM's `vms` dictionary key (its
    /// bundle UUID string) in the sidebar.
    var selectedVM: String?

    /// Running VM instances, keyed by the same `vms` dictionary key.
    var runningVMs: [String: VirtualMachine] = [:]

    /// Latest SPICE clipboard-bridge snapshot per running VM,
    /// pushed by the guest-tools app via the
    /// `GuestEvent.spiceStatus(_:)` topic on the event
    /// stream. Consumed by the workspace toolbar's tri-state
    /// clipboard pill.
    ///
    /// Defaults to ``SpiceClipboardState/notStarted`` on the
    /// very first read (dictionary absence) so the UI shows
    /// a gray pill before the first event arrives — matching
    /// reality: we haven't heard from the agent yet.
    var clipboardStatuses: [String: SpiceStatusSnapshot] = [:]

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

    /// Per-VM host-side metrics sampler. Each running VM
    /// gets one; `sample()` is driven at ~1 Hz from a
    /// publisher Task in ``startStreamingServices``.
    ///
    /// This is the *default* metrics source — no in-guest
    /// agent required. Reads CPU time + memory footprint
    /// from the VM's backing XPC helper process via
    /// `proc_pid_rusage`, which Activity Monitor and
    /// `powermetrics` use too. The in-guest agent remains
    /// available as an opt-in for richer data (frontmost
    /// app, per-process tree, guest load average).
    private var hostSamplers: [String: HostMetricsSampler] = [:]

    /// Macos notification poster for VM lifecycle transitions.
    let notifications = VMNotifications()

    /// Whether the ⌘K command palette is currently presented.
    var showCommandPalette: Bool = false

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

    /// Success / informational message shown after operations
    /// like "Install Agent" that would otherwise complete
    /// silently. Separate from `errorMessage` so success and
    /// failure get visually distinct dialogs.
    var infoMessage: String?

    /// Whether the info banner is presented.
    var infoPresented: Bool = false

    /// Set of VM names whose Guest Tools have been successfully
    /// installed at least once. Persisted across app launches
    /// via `UserDefaults` so the UI can reflect install state
    /// without re-mounting the guest disk to probe for the
    /// `/Applications/Spooktacular Guest Tools.app` path.
    ///
    /// Populated on a successful ``installGuestTools(_:)`` and
    /// on any guest-agent connection observed by
    /// `AgentEventListener` — which means running-with-metrics
    /// VMs self-register even if the original install was via
    /// the CLI.
    ///
    /// Not authoritative (the `.app` could be manually deleted
    /// from inside the guest), but good enough for a "Guest
    /// Tools Installed ✓" button label that replaces the
    /// affordance once the op is known to have succeeded.
    var guestToolsInstalled: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "spook.guestToolsInstalled") ?? []
    ) {
        didSet {
            UserDefaults.standard.set(
                Array(guestToolsInstalled),
                forKey: "spook.guestToolsInstalled"
            )
        }
    }

    // MARK: - Sheet Presentation

    /// Whether the "Create VM" sheet is showing.
    var showCreateSheet = false

    /// If non-nil when the Create VM sheet opens, pre-seeds the
    /// sheet's IPSW source to `.local` with this path. Set by
    /// "Create VM from image" in the image detail view so the
    /// sheet picks up the image the user just selected instead
    /// of defaulting to Apple's latest download.
    var pendingCreateIpswPath: String?

    /// Sibling of ``pendingCreateIpswPath`` for Linux installer
    /// ISOs. When set, the Create sheet's `.onAppear` switches
    /// `guestOS` to `.linux` and prefills the installer-ISO
    /// path. Without this split, "Create VM from image" on an
    /// ISO-in-the-image-library would route through the macOS
    /// IPSW path and Apple's `VZMacOSRestoreImage.load(from:)`
    /// would reject the file as the wrong type.
    var pendingCreateISOPath: String?

    /// Whether the "Add Image" sheet is showing.
    var showAddImage = false

    /// One `VZVirtualMachineView` per running VM, pre-created
    /// BEFORE `VZVirtualMachine.start()` so the framebuffer
    /// pipeline is subscribed at boot time — matches Apple's
    /// "Running macOS in a Virtual Machine" sample order.
    ///
    /// If we instead created the view inside SwiftUI's
    /// `NSViewRepresentable.makeNSView` (i.e., after the VM
    /// had already started), the VZ framework would buffer
    /// the guest's initial frames and a later view-attach
    /// wouldn't reliably flush them — surfacing as a blank
    /// workspace window. Keeping the view alive here means
    /// `VMDisplayView` is a thin wrapper that returns the
    /// already-attached NSView every time SwiftUI calls
    /// `makeNSView`, instead of creating a fresh view each
    /// time the workspace window opens/closes.
    ///
    /// Nulled out in `stopVM` / `deleteVM` so the next start
    /// cycle allocates a fresh view (and a fresh framebuffer
    /// subscription).
    var graphicsViews: [String: VZVirtualMachineView] = [:]

    // MARK: - Pending creations
    //
    // When the Create sheet kicks off a create, we move the
    // entire pipeline into AppState so the sheet can dismiss
    // immediately without stranding the Task. The sidebar
    // renders each entry as a live progress row — ProgressView
    // + status text + cancel/dismiss affordance — so the user
    // can keep working with other VMs while a long macOS IPSW
    // download + install runs in the background.

    /// One row per in-flight or errored VM creation, keyed by
    /// the target VM name. Dropped on success (the VM then
    /// appears as a normal `VMRow` once `loadVMs()` picks up
    /// the written bundle). Left populated on error so the
    /// user can read the failure + explicitly dismiss.
    var pendingCreations: [String: PendingCreation] = [:]

    /// Live state of a creation. Observable via `@Observable` on
    /// AppState; SwiftUI redraws the pending sidebar row as
    /// progress/status fields mutate.
    struct PendingCreation: Identifiable, Sendable {
        let id = UUID()
        let name: String
        let guestOSLabel: String
        var progress: Double = 0
        var statusMessage: String = "Queued…"
        var errorMessage: String?
        /// Task handle so the sidebar row's cancel button can
        /// trigger cooperative cancellation via
        /// `Task.checkCancellation()` inside the pipeline.
        var cancellationTask: Task<Void, Never>?
    }

    /// Updates progress + status for a pending creation. Called
    /// from the creation pipeline at every stage boundary
    /// (download, install, disk inject) so the sidebar row
    /// animates smoothly.
    func updateCreation(name: String, progress: Double, status: String) {
        pendingCreations[name]?.progress = progress
        pendingCreations[name]?.statusMessage = status
    }

    /// Marks a pending creation as failed. Row stays visible
    /// with the error text until the user clicks the dismiss
    /// glyph, so partial-failure diagnosis isn't lost behind a
    /// transient alert.
    func failCreation(name: String, message: String) {
        pendingCreations[name]?.errorMessage = message
        pendingCreations[name]?.statusMessage = "Failed"
    }

    /// Removes a failed (or cancelled) pending row from the
    /// sidebar.
    func dismissPending(_ name: String) {
        pendingCreations.removeValue(forKey: name)
    }

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
            selectedVM = bundle.id.uuidString
            AccessibilityNotification.Announcement(
                "Imported virtual machine \(bundle.displayName)"
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
    /// - Parameters:
    ///   - recovery: When `true`, boots the guest into macOS
    ///     Recovery via
    ///     `VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery`.
    ///     Useful for filesystem repair, Startup Security Utility,
    ///     or reinstalling the OS. Defaults to `false`.
    ///   - guestProvisioning: Applied only when this happens to be
    ///     the bundle's actual first boot after install —
    ///     `VZMacGuestProvisioningOptions` is evaluated solely on
    ///     that boot (macOS 27+ guests; silently ignored otherwise).
    ///     Passed by ``provisionGitHubRunnerForCreate(bundle:runnerSpec:displayName:cancellationTask:)``
    ///     for the runner's own first boot; `nil` for every other
    ///     caller (a manual sidebar Start on an existing VM is never
    ///     a first boot).
    func startVM(
        _ name: String,
        recovery: Bool = false,
        guestProvisioning: GuestProvisioningSpec? = nil
    ) async {
        guard let bundle = vms[name], runningVMs[name] == nil else { return }
        guard !transitioningVMs.contains(name) else { return }

        transitioningVMs.insert(name)
        defer { transitioningVMs.remove(name) }

        do {
            // Post-release-tolerant construction: this method is
            // called by `provisionGitHubRunnerForCreate` for the
            // bundle's actual first boot (no prior VM boot on this
            // bundle to race against), and by the user right after a
            // manual Stop — in the latter case the stopped VM's XPC
            // service can still hold the bundle's file lock for a
            // few seconds (the same documented 5-30s window
            // `isDiskInUse` pre-flights for agent install). On a
            // cold start the first attempt succeeds and the retry
            // never engages. See
            // `VirtualMachine.makeAfterInstall(bundle:onRetry:)`.
            let vm = try await VirtualMachine.makeAfterInstall(bundle: bundle)

            // Pre-create the VZVirtualMachineView and wire it
            // to the VM BEFORE start(). Apple's VZ framework
            // subscribes the guest's graphics device to
            // whatever `view.virtualMachine` points at when
            // the guest issues its first framebuffer command.
            // If the view doesn't exist yet at boot, those
            // early commands get buffered and a later attach
            // doesn't reliably flush them (blank workspace).
            //
            // The view can live detached from any window
            // until WorkspaceWindow opens — the VZ pipeline
            // only needs the view-to-VM association, not a
            // window hierarchy, at subscription time.
            if let vzVM = vm.vzVM {
                let view = VZVirtualMachineView()
                view.virtualMachine = vzVM
                view.capturesSystemKeys = true
                view.automaticallyReconfiguresDisplay = true
                view.setAccessibilityLabel("Virtual machine display for \(bundle.displayName)")
                view.setAccessibilityRole(.group)
                graphicsViews[name] = view
            }

            // Snapshot existing Virtualization-XPC child PIDs
            // *before* start. After start(), the new child(ren)
            // belong to this VM and become our metrics targets.
            // Read more about the attribution technique on
            // `HostMetricsSampler.init(pidsBeforeStart:)`.
            let preStartPIDs = HostMetricsSampler.captureVirtualizationPIDs()

            // `startOrResume` transparently restores from a saved-
            // state file when one exists (the "close the laptop"
            // workflow from Suspend), falling back to a cold boot
            // if restore fails or when booting into Recovery.
            try await vm.startOrResume(startUpFromMacOSRecovery: recovery, guestProvisioning: guestProvisioning)
            runningVMs[name] = vm

            // Host-side metrics sampler. Created eagerly —
            // every macOS / Linux VM gets one. No entitlement,
            // no sudo, no in-guest agent required. The
            // sampler's publisher Task is spawned by
            // ``startStreamingServices(for:vm:)`` below so
            // frames start flowing within ~1s of VM start.
            hostSamplers[name] = HostMetricsSampler(
                vmName: name,
                vCPUs: bundle.spec.cpuCount,
                memoryTotalBytes: bundle.spec.memorySizeInBytes,
                pidsBeforeStart: preStartPIDs
            )

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
                "Virtual machine \(bundle.displayName) started"
            ).post()
            notifications.notifyStarted(name, displayName: bundle.displayName)
        } catch {
            notifications.notifyFailed(name, displayName: bundle.displayName, error: error.localizedDescription)
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
    /// - **`.ports`** — fed from the same ``AgentEventListener``
    ///   stream as `.metrics`, demuxed by `GuestEvent` case below.
    ///
    /// Each publisher runs in its own `Task` so failure of one
    /// (e.g., an older guest agent that doesn't speak
    /// `/api/v1/stats/stream`) doesn't take down the others.
    /// Publisher loops exit cleanly when
    /// ``stopStreamingServices(for:)`` cancels them.
    private func startStreamingServices(for name: String, vm: VirtualMachine) async {
        do {
            // `name` here is still the user-facing key AppState
            // uses for its dictionaries during the UUID
            // transition. The socket path keys on the VM's
            // stable UUID (from metadata), so multiple VMs
            // sharing a display name don't collide on disk.
            guard let bundle = vms[name] else { return }
            let socketURL = SpooktacularPaths.apiSocketURL(for: bundle.id)
            let server = VMStreamingServer(vmName: name, socketURL: socketURL)
            try await server.start()
            streamingServers[name] = server

            var tasks: [Task<Void, Never>] = []

            // Host-side metrics publisher — the default data
            // source for the sidebar chart. Polls the VM's
            // backing XPC process at ~1 Hz via `libproc`; no
            // in-guest agent, no admin prompt, starts
            // immediately on VM start.
            //
            // Every tick does two things:
            //
            //   1. Publish to ``VMStreamingServer`` on the
            //      `.metrics` topic — reachable by any
            //      external consumer on the UDS (CLI,
            //      dashboards, Prometheus scrape).
            //   2. Inject a synthetic ``GuestEvent.stats``
            //      into the ``AgentEventListener`` bus — the
            //      same bus the in-GUI chart
            //      (``WorkspaceStatsModel``) subscribes to.
            //      The chart treats host-sampled and
            //      guest-pushed frames identically; if the
            //      user later installs the guest agent for
            //      richer data, the agent's frames are
            //      newer on the same bus and naturally
            //      win.
            let listener = vm.agentEventListener()
            if let sampler = hostSamplers[name] {
                tasks.append(Task { [weak server, weak listener] in
                    while !Task.isCancelled {
                        let snapshot = await sampler.sample()
                        await server?.publish(topic: .metrics, payload: snapshot)

                        let synthetic = GuestStatsResponse(
                            cpuUsage: snapshot.cpuUsage,
                            memoryUsedBytes: snapshot.memoryUsedBytes,
                            memoryTotalBytes: snapshot.memoryTotalBytes,
                            loadAverage1m: snapshot.loadAverage1m,
                            processCount: snapshot.processCount,
                            uptime: snapshot.uptime,
                            diskBytesRead: snapshot.diskBytesRead,
                            diskBytesWritten: snapshot.diskBytesWritten,
                            energyNanoJoules: snapshot.energyNanoJoules,
                            pageIns: snapshot.pageIns
                        )
                        await MainActor.run { [weak listener] in
                            listener?.inject(.stats(synthetic))
                        }

                        do {
                            try await Task.sleep(for: .seconds(1))
                        } catch {
                            return
                        }
                    }
                })
            }

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
                tasks.append(Task { [weak server, weak self] in
                    do {
                        for try await event in listener.events() {
                            guard !Task.isCancelled else { return }
                            // Deliberately NOT touching
                            // `guestToolsInstalled` here. This
                            // subscriber sees every event on the
                            // bus — real guest-originated frames
                            // AND the synthetic `.stats` frame the
                            // host-metrics sampler above injects
                            // once per second for every started
                            // VM (`AgentEventListener.inject`).
                            // Treating "any event arrived" as
                            // proof Guest Tools are running
                            // therefore false-positives within
                            // ~1s of starting ANY macOS VM,
                            // including ones created with Guest
                            // Tools explicitly disabled. The only
                            // honest signal is a completed
                            // install: `installGuestTools(_:)` and
                            // `provisionBundleForCreate` both mark
                            // `guestToolsInstalled` themselves,
                            // right after `DiskInjector.installGuestTools`
                            // actually succeeds.
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
                            case .spiceStatus(let snapshot):
                                // SPICE clipboard-bridge state
                                // pushed by the guest-tools
                                // app. Stored on AppState so
                                // the workspace toolbar can
                                // read it without polling;
                                // MainActor hop because
                                // `clipboardStatuses` is
                                // @Observable state on the
                                // MainActor.
                                if let self {
                                    await MainActor.run {
                                        self.clipboardStatuses[name] = snapshot
                                    }
                                }
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
        let displayName = vms[name]?.displayName ?? name

        transitioningVMs.insert(name)
        defer { transitioningVMs.remove(name) }

        do {
            try await vm.suspend()
            runningVMs.removeValue(forKey: name)
            clipboardStatuses.removeValue(forKey: name)
            // Drop the pre-created VZVirtualMachineView so the
            // next start cycle allocates a fresh one (and a
            // fresh framebuffer subscription).
            graphicsViews.removeValue(forKey: name)
            hostSamplers.removeValue(forKey: name)
            await stopStreamingServices(for: name)

            AccessibilityNotification.Announcement(
                "Virtual machine \(displayName) suspended"
            ).post()
            notifications.notifyStopped(name, displayName: displayName)
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
        let displayName = vms[name]?.displayName ?? name

        transitioningVMs.insert(name)
        defer { transitioningVMs.remove(name) }

        do {
            try await vm.stop(graceful: false)
            runningVMs.removeValue(forKey: name)
            clipboardStatuses.removeValue(forKey: name)
            // Drop the pre-created VZVirtualMachineView so the
            // next start cycle allocates a fresh one (and a
            // fresh framebuffer subscription).
            graphicsViews.removeValue(forKey: name)
            hostSamplers.removeValue(forKey: name)
            await stopStreamingServices(for: name)

            AccessibilityNotification.Announcement(
                "Virtual machine \(displayName) stopped"
            ).post()
            notifications.notifyStopped(name, displayName: displayName)
        } catch {
            presentError(error)
        }
    }

    // MARK: - Creation pipeline

    /// Parameters the Create sheet hands to AppState when the
    /// user confirms. Packaged so the sheet can dismiss
    /// immediately while the Task keeps running.
    struct MacOSCreationRequest: Sendable {
        let name: String
        let spec: VirtualMachineSpecification
        /// `.local` → use `localIpswPath`; `.latest` → download.
        let ipswSource: IPSWSource
        let localIpswPath: String
        /// If non-nil, injected at first boot via
        /// ``SpooktacularInfrastructureApple/DiskInjector/inject(script:into:)``.
        /// Already-resolved URL + ownership flag so the
        /// sheet's keychain / template resolution happens
        /// before we dismiss the create sheet.
        let userScriptURL: URL?
        let ownsUserScript: Bool
        /// Non-nil when the sheet's provisioning template is
        /// GitHub Actions Runner. Unlike ``userScriptURL``, this
        /// carries no secret — the Keychain lookup and
        /// registration-token mint happen late, in
        /// ``runMacOSCreate(request:)``, seconds before the VM
        /// boots. See ``RunnerRequest``.
        let runnerSpec: RunnerRequest?

        enum IPSWSource: Sendable { case latest, local }
    }

    struct LinuxCreationRequest: Sendable {
        let name: String
        let spec: VirtualMachineSpecification
        let installerISOPath: String
    }

    /// Kicks off a macOS VM create in the background. Returns
    /// immediately; progress flows through
    /// ``pendingCreations``.
    func beginCreateMacOSVM(_ request: MacOSCreationRequest) {
        let name = request.name
        // Display-name uniqueness is no longer a hard error
        // under the UUID primary-key scheme — bundle
        // directories are `<uuid>.vm` so two VMs named "test"
        // coexist on disk without colliding. AppState's
        // pending/vms dicts still use the display name as the
        // key for now (transitional), so only an in-flight
        // create with the exact same name blocks a new one.
        guard pendingCreations[name] == nil else {
            presentError(SpooktacularError.invalidVMName(reason: "A VM named '\(name)' is already being created. Dismiss or wait for the existing creation to finish."))
            return
        }
        pendingCreations[name] = PendingCreation(
            name: name,
            guestOSLabel: "macOS Virtual Machine"
        )
        let task = Task { @MainActor in
            await runMacOSCreate(request: request)
        }
        pendingCreations[name]?.cancellationTask = task
    }

    /// Linux counterpart — shorter pipeline (no IPSW, no
    /// `VZMacOSInstaller`, just bundle + disk + ISO copy).
    func beginCreateLinuxVM(_ request: LinuxCreationRequest) {
        let name = request.name
        guard pendingCreations[name] == nil else {
            presentError(SpooktacularError.invalidVMName(reason: "A VM named '\(name)' is already being created. Dismiss or wait for the existing creation to finish."))
            return
        }
        pendingCreations[name] = PendingCreation(
            name: name,
            guestOSLabel: "Linux Virtual Machine"
        )
        let task = Task { @MainActor in
            await runLinuxCreate(request: request)
        }
        pendingCreations[name]?.cancellationTask = task
    }

    /// Cancels the in-flight create Task. The pipeline's
    /// `Task.checkCancellation()` points throw, the `catch
    /// CancellationError` branch cleans up any partial bundle,
    /// and the row moves to an errored-dismissable state.
    func cancelPending(_ name: String) {
        pendingCreations[name]?.cancellationTask?.cancel()
    }

    // MARK: - Creation pipeline (private)

    @MainActor
    private func runMacOSCreate(request: MacOSCreationRequest) async {
        let name = request.name
        // Captured now, before anything below touches
        // `pendingCreations[name]` — `beginCreateMacOSVM` sets this
        // synchronously, on the same actor, immediately after
        // scheduling the `Task` that runs this method, so it's
        // guaranteed populated by the time this line executes.
        // Re-threaded into `provisionGitHubRunnerForCreate` so its
        // re-populated pending-creation row keeps working Cancel
        // support instead of silently losing the handle when the
        // base pipeline's own success tail removes this row below.
        let cancellationTask = pendingCreations[name]?.cancellationTask
        // Mint the VM's permanent UUID upfront so the bundle
        // directory, metadata, and any recovery-cleanup path
        // all agree on a single identity. Two parallel creates
        // with the same display name get different UUIDs and
        // different bundle directories — the failure/collision
        // semantics are display-name-independent.
        let bundleID = UUID()
        let bundleURL: URL? = SpooktacularPaths.bundleURL(for: bundleID)
        let manager = RestoreImageManager(cacheDirectory: ipswCacheDirectory)

        // Captured across the do/catch boundary below so the
        // runner-provisioning phase at the bottom of this method
        // — deliberately OUTSIDE the do/catch, see its call site —
        // has what it needs without re-deriving it.
        var createdBundle: VirtualMachineBundle?

        // Fail fast, BEFORE the IPSW download and 10-20 minute macOS
        // install begin: a --github-runner create injects a
        // root:wheel LaunchDaemon (see
        // ``provisionGitHubRunnerForCreate(bundle:runnerSpec:displayName:cancellationTask:)``),
        // which requires running with root privileges on the host.
        // Mirrors the CLI's `DirectPrivilegedFileOps().preflight()`
        // guard in `Create.swift`, which runs before its own install
        // begins — without this, a non-root GUI launch burns the
        // whole install before failing.
        if request.runnerSpec != nil {
            do {
                try DirectPrivilegedFileOps().preflight()
            } catch {
                failCreation(
                    name: name,
                    message: "Runner provisioning requires Spooktacular to run as root; this "
                        + "is supported for the root-service/EC2 Mac deployment, not an "
                        + "ordinary desktop launch."
                )
                return
            }
        }

        do {
            // Restore-image resolution is source-dependent.
            //
            //   - `.local`  — load the user's on-disk IPSW via
            //     `VZMacOSRestoreImage.image(from:)`. No network
            //     I/O; `fetchLatestSupported()`'s call to Apple's
            //     catalog is not required here.
            //   - `.latest` — fetch from Apple's catalog to learn
            //     the current IPSW URL, then resume-download.
            //
            // Previously this path unconditionally called
            // `fetchLatestSupported()` before branching, which
            // made every create (including local-IPSW creates)
            // depend on Apple's catalog reachability — a single
            // "restore image catalog failed to load" bubbled up
            // from a network failure on the host blocked users
            // who already had the IPSW on disk.
            let restoreImage: VZMacOSRestoreImage
            let ipswURL: URL
            switch request.ipswSource {
            case .local:
                let expanded = (request.localIpswPath as NSString).expandingTildeInPath
                let candidate = URL(filePath: expanded)
                guard FileManager.default.fileExists(atPath: candidate.path) else {
                    failCreation(name: name, message: "IPSW file not found at '\(expanded)'.")
                    return
                }
                updateCreation(name: name, progress: 0, status: "Loading local IPSW…")
                restoreImage = try await VZMacOSRestoreImage.image(from: candidate)
                try Task.checkCancellation()
                ipswURL = candidate
                let v = restoreImage.operatingSystemVersion
                updateCreation(
                    name: name,
                    progress: 0.5,
                    status: "Using macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) from \(candidate.lastPathComponent)…"
                )
            case .latest:
                updateCreation(name: name, progress: 0, status: "Fetching restore image info…")
                restoreImage = try await manager.fetchLatestSupported()
                try Task.checkCancellation()
                let v = restoreImage.operatingSystemVersion
                updateCreation(
                    name: name,
                    progress: 0.05,
                    status: "Found macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
                )
                updateCreation(name: name, progress: 0.05, status: "Downloading kernel and firmware…")
                ipswURL = try await manager.downloadIPSW(from: restoreImage) { [weak self] snap in
                    Task { @MainActor in
                        let pct = Int(snap.fraction * 100)
                        let msg = snap.resumed
                            ? "Resuming IPSW download (\(pct)%)…"
                            : "Downloading IPSW (\(pct)%)…"
                        self?.updateCreation(
                            name: name,
                            progress: 0.05 + snap.fraction * 0.45,
                            status: msg
                        )
                    }
                }
            }
            try Task.checkCancellation()

            // Fail fast if this is a --github-runner create whose
            // resolved guest image is below the macOS 27
            // native-guest-provisioning floor — BEFORE the bundle is
            // created and the 10-20 minute install begins. See
            // ``RunnerCreateFlowPlan/validateGuestOSFloor(majorVersion:)``.
            if request.runnerSpec != nil {
                try RunnerCreateFlowPlan.validateGuestOSFloor(
                    majorVersion: restoreImage.operatingSystemVersion.majorVersion
                )
            }

            updateCreation(name: name, progress: 0.5, status: "Writing base disk…")
            let bundle = try await manager.createBundle(
                id: bundleID,
                displayName: name,
                in: vmsDirectory,
                from: restoreImage,
                spec: request.spec
            )
            try Task.checkCancellation()

            updateCreation(name: name, progress: 0.55, status: "Installing macOS…")
            try await manager.install(bundle: bundle, from: ipswURL) { [weak self] fraction in
                Task { @MainActor in
                    self?.updateCreation(
                        name: name,
                        progress: 0.55 + fraction * 0.4,
                        status: "Installing macOS (\(Int(fraction * 100))%)…"
                    )
                }
            }
            try Task.checkCancellation()

            // Provisioner daemon injection. A GUI create with a
            // template (Remote Desktop / OpenClaw) or
            // operator-supplied `--user-data` script writes
            // `first-boot.sh` to the bundle's provisioning share
            // below via `provisionBundleForCreate`, but that script
            // is only ever EXECUTED by the guest's Spooktacular
            // Provisioner LaunchDaemon, injected directly onto the
            // guest's Data volume before first boot (see
            // ``DiskInjector/installProvisionerDaemon``) — replacing
            // the old Setup Assistant + pkg-install path. No OS boot
            // needed to install it. Mirrors the CLI's
            // `willInjectFirstBootScript` gate, generalized to any
            // script source. Non-fatal on failure: the VM is still a
            // perfectly usable desktop VM once the operator installs
            // the daemon or completes setup by hand.
            //
            // Excludes --github-runner creates: the runner path
            // injects the daemon itself, later, in
            // ``provisionGitHubRunnerForCreate(bundle:runnerSpec:displayName:cancellationTask:)``,
            // right before it disk-injects the runner script — and
            // treats that injection as fatal, unlike this soft-fail
            // path. Without this exclusion, a runner create with the
            // default Guest Tools install (`.installed`, which
            // `installsAppBundle`) would inject the daemon twice: once
            // here (soft-fail), then again in the runner phase
            // (hard-fail on the now-already-injected daemon).
            let willInjectFirstBootScript = request.userScriptURL != nil
            if (willInjectFirstBootScript || bundle.spec.guestToolsInstall.installsAppBundle)
                && request.runnerSpec == nil {
                if let assets = ProvisionerAssets.locate() {
                    do {
                        try DiskInjector.installProvisionerDaemon(
                            into: bundle,
                            plist: assets.plist,
                            runner: assets.runner,
                            privileged: DirectPrivilegedFileOps()
                        )
                    } catch {
                        Log.provision.error(
                            "Provisioner daemon injection failed for '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                        )
                        notifications.notifyWarning(
                            bundleID.uuidString,
                            displayName: name,
                            body: "Provisioner daemon injection failed, so the first-boot script may not run automatically. Start the VM to complete setup and run it by hand."
                        )
                    }
                } else {
                    Log.provision.warning(
                        "Provisioner assets not found — skipping daemon injection for '\(name, privacy: .public)'. Run build-app.sh to produce Resources/SpookProvisioner/."
                    )
                }
            }

            // Provisioning phase. Runs when EITHER:
            //
            //   - the spec requests Guest Tools install
            //     (`.installed`), OR
            //   - the user supplied a first-boot script
            //     (template or `--user-data`).
            //
            // `provisionBundleForCreate` handles both
            // independently — Guest Tools via `ditto` (fully
            // unprivileged — launch-at-login is the guest app's own
            // concern, not the host installer's), user scripts via
            // `DiskInjector.inject(script:)`, a plain host-side copy
            // into the bundle's provisioning share (no root needed;
            // the daemon that will read it back was already injected
            // above). Runs regardless of the daemon-injection outcome
            // above — even if it failed or the assets weren't found,
            // the script is still written to the share so it's there
            // once the operator installs the daemon or completes
            // setup by hand.
            let needsProvisioning =
                bundle.spec.guestToolsInstall.installsAppBundle
                || request.userScriptURL != nil
            if needsProvisioning {
                updateCreation(name: name, progress: 0.95, status: "Provisioning guest…")
                try await provisionBundleForCreate(
                    bundle: bundle,
                    userScriptURL: request.userScriptURL,
                    ownsUserScript: request.ownsUserScript
                )
            }

            createdBundle = bundle
            pendingCreations.removeValue(forKey: name)
            loadVMs()
            // `selectedVM` indexes `vms` (keyed by UUID), never
            // the display name the user typed — see `vms`'s doc
            // comment. `bundle.id` is minted upfront in this
            // method as `bundleID`, so it's already known to
            // match the directory `RestoreImageManager.createBundle`
            // just wrote and the key `loadVMs()` just populated.
            selectedVM = bundle.id.uuidString
            // Fire-and-forget accessibility announcement; the
            // VM now shows up as a VMRow in the sidebar via
            // loadVMs(), which is the real confirmation.
            AccessibilityNotification.Announcement(
                "Virtual machine \(name) created"
            ).post()
        } catch is CancellationError {
            if let url = bundleURL {
                try? FileManager.default.removeItem(at: url)
            }
            pendingCreations.removeValue(forKey: name)
        } catch {
            if let url = bundleURL {
                try? FileManager.default.removeItem(at: url)
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failCreation(name: name, message: msg)
        }

        // GitHub Actions runner provisioning — mirrors Create.swift's
        // `provisionGitHubRunner`, which deliberately runs OUTSIDE its
        // do/catch for the same reason: by this point the VM has been
        // created successfully (the guard below requires
        // `createdBundle`, which is only set on the success path
        // above), and it's already visible in the sidebar via
        // `loadVMs()`. A late failure here (Keychain miss, GitHub API
        // error, boot failure) must NOT delete a bundle that took
        // 10-20 minutes to install — see
        // ``provisionGitHubRunnerForCreate(bundle:runnerSpec:displayName:cancellationTask:)``.
        if let runnerSpec = request.runnerSpec, let createdBundle {
            await provisionGitHubRunnerForCreate(
                bundle: createdBundle,
                runnerSpec: runnerSpec,
                displayName: name,
                cancellationTask: cancellationTask
            )
        }
    }

    @MainActor
    private func runLinuxCreate(request: LinuxCreationRequest) async {
        let name = request.name
        // Mint UUID upfront — matches `runMacOSCreate`'s shape.
        let bundleID = UUID()
        let target = SpooktacularPaths.bundleURL(for: bundleID)

        let trimmedISO = request.installerISOPath.trimmingCharacters(in: .whitespaces)
        let expandedISO = (trimmedISO as NSString).expandingTildeInPath
        let isoURL = URL(filePath: expandedISO)
        guard FileManager.default.fileExists(atPath: isoURL.path) else {
            failCreation(name: name, message: "Installer ISO not found at '\(expandedISO)'.")
            return
        }

        do {
            try Task.checkCancellation()
            updateCreation(name: name, progress: 0.1, status: "Creating bundle…")
            let bundle = try VirtualMachineBundle.create(
                at: target,
                spec: request.spec,
                displayName: name
            )

            updateCreation(name: name, progress: 0.2, status: "Allocating \(request.spec.diskSizeInGigabytes) GB disk…")
            let diskURL = target.appendingPathComponent(VirtualMachineBundle.diskImageFileName)
            let format = try await DiskImageAllocator.create(
                at: diskURL,
                sizeInBytes: request.spec.diskSizeInBytes
            )
            updateCreation(name: name, progress: 0.4, status: "Allocated \(format.rawValue.uppercased()) disk…")
            try Task.checkCancellation()

            updateCreation(name: name, progress: 0.6, status: "Copying installer ISO…")
            try FileManager.default.copyItem(at: isoURL, to: bundle.installerISOURL)
            updateCreation(name: name, progress: 0.95, status: "Finalizing…")

            pendingCreations.removeValue(forKey: name)
            loadVMs()
            // See the matching comment in `runMacOSCreate` —
            // `selectedVM` indexes `vms` by UUID, not display name.
            selectedVM = bundle.id.uuidString
            // Fire-and-forget accessibility announcement; the
            // VM now shows up as a VMRow in the sidebar via
            // loadVMs(), which is the real confirmation.
            AccessibilityNotification.Announcement(
                "Virtual machine \(name) created"
            ).post()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: target)
            pendingCreations.removeValue(forKey: name)
        } catch {
            try? FileManager.default.removeItem(at: target)
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failCreation(name: name, message: msg)
        }
    }

    /// Builds the combined agent-bootstrap + optional user
    /// script and disk-injects it. Same shape as the sheet's
    /// old `provisionBundle(_:)` but wired to publish into
    /// `pendingCreations` rather than local sheet state.
    @MainActor
    private func provisionBundleForCreate(
        bundle: VirtualMachineBundle,
        userScriptURL: URL?,
        ownsUserScript: Bool
    ) async throws {
        let install = bundle.spec.guestToolsInstall

        // 1. Guest Tools install — the Apple-native direct-copy
        //    path. Honours the two-way user choice:
        //      .disabled   → skip entirely
        //      .installed  → ditto `.app` into /Applications/
        //
        //    Launch-at-login is owned by the guest app's own
        //    `SMAppService.mainApp`-backed menu-bar toggle,
        //    not the host installer, so this path is fully
        //    unprivileged — no `/Library/LaunchAgents/`
        //    plist, no `chownToRoot`, no admin prompt.
        //
        //    The locator returns `nil` during developer
        //    iteration (when `build-app.sh` hasn't produced
        //    the nested bundle yet). That's a soft failure:
        //    we log a warning and continue with user script
        //    provisioning so the create flow isn't blocked by
        //    a missing dev artifact.
        if install.installsAppBundle {
            if let appBundle = AppBundleBootstrapTemplate.locateGuestToolsBundle() {
                try await Task.detached(priority: .userInitiated) {
                    try DiskInjector.installGuestTools(
                        appBundle: appBundle,
                        into: bundle
                    )
                }.value
                // Verified signal, not a guess: the ditto copy
                // above just returned successfully. Matches
                // `installGuestTools(_:)`'s own post-install
                // bookkeeping so a VM created with Guest Tools
                // enabled shows "Guest Tools Installed ✓"
                // immediately, without needing a guest-originated
                // event to arrive first.
                guestToolsInstalled.insert(bundle.id.uuidString)
            } else {
                Log.provision.warning(
                    "Guest Tools bundle not found — skipping install (user chose \(install.rawValue, privacy: .public)). Run build-app.sh to produce Contents/Applications/Spooktacular Guest Tools.app."
                )
            }
        }

        // 2. User-provided provisioning script — independent
        //    of Guest Tools. Injected via the legacy
        //    script+LaunchDaemon path so workload templates
        //    (GitHub runner, OpenClaw, remote desktop) keep
        //    working during the Phase-3 transition.
        if let userScriptURL {
            try await Task.detached(priority: .userInitiated) {
                try DiskInjector.inject(script: userScriptURL, into: bundle)
            }.value
            if ownsUserScript {
                try? ScriptFile.cleanup(scriptURL: userScriptURL)
            }
        }
    }

    /// Zero-touch GitHub Actions runner provisioning for a freshly
    /// created macOS VM. Mirrors `Create.swift`'s
    /// `provisionGitHubRunner` → `bootRunnerAndAwaitOnline` chain,
    /// adapted to the GUI's in-process VM lifecycle: no PID file and
    /// no headless-process signal handling — the running app itself
    /// is the long-lived host process, and
    /// ``startVM(_:recovery:guestProvisioning:)`` /
    /// ``stopVM(_:)`` already own that bookkeeping.
    ///
    /// Called from ``runMacOSCreate(request:)`` **after** its
    /// do/catch has already revealed the VM in the sidebar
    /// (`loadVMs()` ran; the bundle exists on disk). A failure in
    /// any stage below therefore must NOT delete the bundle — the
    /// VM was already created successfully, exactly like
    /// `Create.swift` keeps the bundle and reports the runner-phase
    /// failure separately from VM creation.
    ///
    /// Re-populates a fresh ``pendingCreations`` row — the base
    /// pipeline's row was already cleared by the success tail this
    /// method is called after — so the sidebar keeps showing live
    /// progress through setup automation, minting, injection, boot,
    /// and the online poll. This reuses the same progress surface
    /// as the IPSW download/install stages rather than introducing
    /// a new one; on completion (success or a non-fatal "not yet
    /// confirmed online" outcome) the row is cleared, and on a hard
    /// failure it's left in its errored state via ``failCreation(name:message:)``
    /// so the user can read it and dismiss.
    ///
    /// ``transitioningVMs`` guards the VM's Start/Stop controls
    /// (see ``startVM(_:recovery:guestProvisioning:)``'s own guard)
    /// for the provisioner-daemon-injection window, since that
    /// attaches/mounts the bundle's disk image outside
    /// ``runningVMs`` — a concurrent user-initiated start would
    /// otherwise race it. The guard is lifted before handing off to
    /// ``startVM(_:recovery:guestProvisioning:)``, which manages its
    /// own insert/remove for the boot it performs.
    ///
    /// - Parameter cancellationTask: The Task handle
    ///   ``beginCreateMacOSVM(_:)`` originally attached to this VM's
    ///   pending-creation row — the SAME task that is currently
    ///   executing this method via `runMacOSCreate(request:)`'s
    ///   plain `await` call, so cancelling it cooperatively trips
    ///   this method's `Task.checkCancellation()` checkpoints.
    ///   Re-attached to the fresh row below so the sidebar's Cancel
    ///   button keeps working — without it, the row this method
    ///   creates would carry a `nil` handle (the original row, and
    ///   its handle, was already removed by the base pipeline's own
    ///   success tail before this method runs) and Cancel would
    ///   silently no-op for the remainder of this phase.
    @MainActor
    private func provisionGitHubRunnerForCreate(
        bundle: VirtualMachineBundle,
        runnerSpec: RunnerRequest,
        displayName: String,
        cancellationTask: Task<Void, Never>?
    ) async {
        let name = displayName
        // `vms` (and therefore `transitioningVMs` / `runningVMs`)
        // is keyed by UUID, not display name — see `vms`'s doc
        // comment. `bundle` was just created by `runMacOSCreate`,
        // so its `id` is the authoritative key `loadVMs()` already
        // populated into `vms` before this method was called.
        // `pendingCreations` is the deliberate exception: it stays
        // keyed by `name` (display name) throughout the whole
        // creation pipeline, bundle or no bundle.
        let key = bundle.id.uuidString
        pendingCreations[name] = PendingCreation(
            name: name,
            guestOSLabel: "GitHub Actions Runner"
        )
        pendingCreations[name]?.cancellationTask = cancellationTask
        transitioningVMs.insert(key)

        do {
            // 1. Inject the provisioner LaunchDaemon directly onto
            //    the guest's Data volume so it's in place before the
            //    runner script is disk-injected below — replacing
            //    the old Setup Assistant + pkg-install path (see
            //    ``DiskInjector/installProvisionerDaemon``). No OS
            //    boot needed. Unlike the non-runner scripted-template
            //    path in `runMacOSCreate(request:)` (which swallows
            //    and warns), a failure here IS fatal: zero-touch
            //    runner registration has nothing to fall back to if
            //    the daemon never lands, so the error propagates to
            //    this method's own `catch` below.
            updateCreation(name: name, progress: 0.05, status: "Injecting provisioner daemon…")
            try DirectPrivilegedFileOps().preflight()
            guard let assets = ProvisionerAssets.locate() else {
                throw RunnerProvisioningError.provisionerAssetsNotFound
            }
            try DiskInjector.installProvisionerDaemon(
                into: bundle,
                plist: assets.plist,
                runner: assets.runner,
                privileged: DirectPrivilegedFileOps()
            )
            try Task.checkCancellation()

            // 2. Native guest provisioning account for this VM's
            //    first boot — the framework creates this admin
            //    account and skips Setup Assistant (macOS 27+ guests
            //    only; see ``GuestProvisioningSpec``). The password
            //    is ephemeral, generated fresh per VM, never
            //    persisted.
            let provisioningSpec = GuestProvisioningSpec(
                fullName: "Spooktacular Runner",
                username: GitHubRunnerTemplate.runnerAccountUsername,
                password: EphemeralCredential.generatePassword()
            )

            // 3. Mint a fresh registration token — seconds before
            //    boot, since GitHub's tokens expire after one
            //    hour and Setup Assistant automation alone can
            //    take several minutes.
            updateCreation(name: name, progress: 0.6, status: "Resolving GitHub token…")
            let pat = try GitHubTokenResolver.resolve(keychainAccount: runnerSpec.keychainAccount)
            let scope = try GitHubRunnerScope("repos/\(runnerSpec.repo)")
            let service = GitHubRunnerService(auth: GitHubPATAuth(token: pat), http: URLSessionHTTPClient())
            updateCreation(name: name, progress: 0.65, status: "Minting registration token…")
            let issued = try await service.issueRegistrationToken(scope: scope)

            // From here on, a live registration token exists at
            // GitHub. Any failure below — including cancellation —
            // must revoke it before propagating: an unspent token
            // stays valid for its full ~1h TTL, which is exactly
            // the "on-host attacker races registration and
            // substitutes their own runner" window the token's
            // 0700 on-disk hardening defends against. Wrapping the
            // remaining steps in one do/catch guarantees the
            // revoke fires on every exit path (script generation,
            // injection, cancellation, the VM failing to start,
            // and cancellation while waiting to come online), not
            // just the two spots a prior revision remembered to
            // call it from by hand.
            do {
                try Task.checkCancellation()

                // 4. Render + inject the runner script. Named
                //    after the VM's display name, matching
                //    `config.sh --name` so `waitForOnline(named:)`
                //    below finds the right runner record.
                updateCreation(name: name, progress: 0.7, status: "Injecting runner setup script…")
                let scriptURL = try GitHubRunnerTemplate.generate(
                    repo: runnerSpec.repo,
                    token: issued.token,
                    labels: runnerSpec.labels,
                    ephemeral: runnerSpec.ephemeral,
                    runnerName: name
                )
                do {
                    try DiskInjector.inject(script: scriptURL, into: bundle)
                } catch {
                    try? ScriptFile.cleanup(scriptURL: scriptURL)
                    throw error
                }
                do {
                    try ScriptFile.cleanup(scriptURL: scriptURL)
                } catch {
                    Log.provision.error("Runner script cleanup failed: \(error.localizedDescription, privacy: .public)")
                }

                // Hand off to the existing GUI start path, which
                // manages its own `transitioningVMs` insert/remove
                // keyed the same way (bundle UUID). Removing our
                // hold here first avoids self-blocking `startVM`'s
                // own re-entrancy guard.
                transitioningVMs.remove(key)
                try Task.checkCancellation()

                // 5. Start via the existing GUI start path — same
                //    method every other VM in the sidebar uses,
                //    keyed by the bundle's UUID, so the VM becomes
                //    a normal running instance in `runningVMs`
                //    with streaming services, graphics view, and
                //    lifecycle notifications wired up. This is the
                //    bundle's actual first boot after install, so
                //    `guestProvisioning` is honored.
                updateCreation(name: name, progress: 0.85, status: "Starting VM…")
                await startVM(key, guestProvisioning: provisioningSpec)
                guard runningVMs[key] != nil else {
                    throw RunnerProvisioningError.startFailed
                }

                // 6. Poll GitHub until the runner reports online. A
                //    timeout here is non-fatal — mirrors the CLI's
                //    `bootRunnerAndAwaitOnline`, which leaves the
                //    VM running and warns rather than tearing
                //    anything down, since the runner may still
                //    come online.
                updateCreation(name: name, progress: 0.9, status: "Waiting for runner to come online…")
                do {
                    let runner = try await service.waitForOnline(
                        named: name,
                        scope: scope,
                        deadline: Date().addingTimeInterval(600),
                        pollInterval: 10
                    )
                    updateCreation(name: name, progress: 1.0, status: "Runner online (GitHub runner id \(runner.id)).")
                } catch {
                    Log.provision.warning(
                        "Runner '\(name, privacy: .public)' not confirmed online: \(error.localizedDescription, privacy: .public)"
                    )
                    updateCreation(
                        name: name,
                        progress: 1.0,
                        status: "VM running — runner not yet confirmed online. Check its provisioning logs."
                    )
                }
            } catch {
                await service.revokeRegistrationToken(handle: issued.handle)
                throw error
            }
            await service.revokeRegistrationToken(handle: issued.handle)

            pendingCreations.removeValue(forKey: name)
        } catch is CancellationError {
            transitioningVMs.remove(key)
            pendingCreations.removeValue(forKey: name)
        } catch {
            transitioningVMs.remove(key)
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failCreation(name: name, message: msg)
        }
    }

    /// Deletes a VM by name, stopping it first if running.
    ///
    /// The published `vms` / `runningVMs` state
    /// is updated **only after** the corresponding side effect
    /// succeeds (stop → remove from runningVMs; FS delete →
    /// remove from vms). Earlier revisions removed from the
    /// observable dictionaries up-front so the sidebar row
    /// disappeared immediately, then on FS-delete failure the
    /// bundle remained on disk with no UI to get it back — the
    /// "row disappeared but error thrown" UX bug the user
    /// flagged.
    ///
    /// Orphaned-on-disk handling: if the bundle directory is
    /// already missing when we try to delete it, treat that as
    /// success (the dict entry is stale — a previous partial
    /// delete or an out-of-band `rm -rf`) and still remove
    /// from `vms` so the row clears.
    func deleteVM(_ name: String) {
        guard let bundle = vms[name] else { return }
        guard !transitioningVMs.contains(name) else { return }

        transitioningVMs.insert(name)
        Task {
            defer { transitioningVMs.remove(name) }
            do {
                // Stop first — but keep runningVMs populated
                // until stop succeeds. A stop failure should
                // leave the row AND the running-state indicator
                // consistent with disk reality.
                if let vm = runningVMs[name] {
                    Log.vm.info("Stopping running VM '\(name, privacy: .public)' before deletion")
                    await stopStreamingServices(for: name)
                    try await vm.stop(graceful: false)
                    runningVMs.removeValue(forKey: name)
                    clipboardStatuses.removeValue(forKey: name)
                    // Drop the pre-created VZVirtualMachineView so the
                    // next start cycle allocates a fresh one (and a
                    // fresh framebuffer subscription).
                    graphicsViews.removeValue(forKey: name)
                    hostSamplers.removeValue(forKey: name)
                }
                // Clear the "Guest Tools installed" flag — the
                // set is keyed by VM name AND persisted to
                // UserDefaults. Without this, deleting a VM
                // and recreating one with the same name leaves
                // the prior VM's installed-flag intact, and
                // `VMDetailView` incorrectly shows "Guest
                // Tools Installed ✓" for the fresh VM.
                // Caught during E2E verification (task #70).
                guestToolsInstalled.remove(name)

                // Delete the bundle directory. If it's already
                // missing, fall through — the dict entry is
                // orphaned.
                let fm = FileManager.default
                if fm.fileExists(atPath: bundle.url.path) {
                    try fm.removeItem(at: bundle.url)
                }
                // Only remove from the observable dict once
                // the filesystem agrees.
                vms.removeValue(forKey: name)
                if selectedVM == name {
                    selectedVM = nil
                }

                AccessibilityNotification.Announcement(
                    "Virtual machine \(bundle.displayName) deleted"
                ).post()
            } catch {
                Log.vm.error("Delete failed for '\(name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
                presentError(error)
                // Re-sync observable state from disk in case
                // stop() partially succeeded.
                loadVMs()
            }
        }
    }

    /// Clones a VM.
    ///
    /// - Parameters:
    ///   - source: The `vms` dictionary key (bundle UUID string)
    ///     of the VM to clone.
    ///   - destination: The clone's user-facing display name —
    ///     NOT a `vms` key. The clone gets its own freshly-minted
    ///     UUID key, matching every other VM in `vms`.
    ///
    /// Marks the destination's UUID key as transitioning for the
    /// duration so the menu-bar icon reflects that a clone is
    /// in progress.
    func cloneVM(_ source: String, to destination: String) {
        do {
            guard let sourceBundle = vms[source] else { return }
            let destinationID = UUID()
            let destinationKey = destinationID.uuidString
            transitioningVMs.insert(destinationKey)
            defer { transitioningVMs.remove(destinationKey) }
            let destinationURL = SpooktacularPaths.bundleURL(for: destinationID)
            let clone = try CloneManager.clone(
                source: sourceBundle,
                to: destinationURL,
                displayName: destination
            )
            // Keyed by the clone's own UUID — never by
            // `destination` (a display name). Inserting under a
            // display-name key would plant a second, incoherent
            // key space inside the same dictionary.
            vms[clone.id.uuidString] = clone

            AccessibilityNotification.Announcement(
                "Virtual machine \(sourceBundle.displayName) cloned to \(destination)"
            ).post()
        } catch {
            presentError(error)
        }
    }

    /// Installs Spooktacular Guest Tools into a stopped VM's
    /// `/Applications/` directory via the Apple-native
    /// direct-copy path (`/usr/bin/ditto`). Invoked from
    /// `VMDetailView`'s "Install Guest Tools" toolbar button
    /// for VMs that were created with
    /// ``GuestToolsInstallMode/disabled`` or whose bundle
    /// pre-dates the install.
    ///
    /// After the VM boots and the user opens Guest Tools
    /// from `/Applications/`, the app's menu-bar UI exposes
    /// an `SMAppService.mainApp`-backed "Launch at Login"
    /// toggle — that's the user's control for auto-start,
    /// not the host installer's decision.
    ///
    /// Requires the VM to be stopped. ``DiskInjector`` uses
    /// `diskutil image attach` which can't mount a disk image
    /// that `VZVirtualMachine` (or its XPC service) currently
    /// has open.
    func installGuestTools(_ name: String) {
        guard let bundle = vms[name] else { return }
        // Guest Tools is a macOS-only `.app`. Calling this on
        // a Linux VM would `ditto` a Mach-O bundle onto an
        // ext4 data volume — almost certainly failing at the
        // `diskutil image attach` step (Linux disks aren't
        // APFS). Guard explicitly so the user sees a clear
        // error instead of a raw hdiutil diagnostic.
        guard bundle.spec.guestOS == .macOS else {
            presentError(GuestToolsInstallError.unsupportedGuestOS)
            return
        }
        guard runningVMs[name] == nil else {
            presentError(GuestToolsInstallError.vmRunning(bundle.displayName))
            return
        }
        guard !transitioningVMs.contains(name) else { return }
        guard let appBundle = AppBundleBootstrapTemplate.locateGuestToolsBundle() else {
            presentError(GuestToolsInstallError.bundleMissing)
            return
        }

        // Defensive: even after a UI-level stop, Apple's VZ XPC
        // service can linger with the guest disk.img still
        // held open for a few seconds. `diskutil image attach`
        // then fails with "Resource temporarily unavailable".
        // `lsof` confirms who holds the fd; this surfaces a
        // clear "try again in a moment" rather than a raw
        // POSIX error.
        if isDiskInUse(bundle: bundle) {
            presentError(GuestToolsInstallError.diskInUse(bundle.displayName))
            return
        }

        transitioningVMs.insert(name)
        Task {
            defer { transitioningVMs.remove(name) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try DiskInjector.installGuestTools(
                        appBundle: appBundle,
                        into: bundle
                    )
                }.value

                // Record the installation so the sidebar +
                // detail-view buttons can reflect "Guest Tools
                // Installed ✓" instead of leaving the user
                // wondering whether to click again.
                guestToolsInstalled.insert(name)

                infoMessage = "Spooktacular Guest Tools installed in '\(bundle.displayName)'. Start the VM, open Spooktacular Guest Tools from /Applications/, and flip the menu-bar 'Launch at Login' toggle to have it start automatically next time."
                infoPresented = true

                AccessibilityNotification.Announcement(
                    "Guest Tools installed in \(bundle.displayName)"
                ).post()
            } catch {
                presentError(error)
            }
        }
    }

    /// Returns `true` if anything (usually a lingering VZ XPC
    /// service after a recent Stop) currently has the bundle's
    /// `disk.img` open. Checked via `lsof` so we don't rely on
    /// our own `runningVMs` dict being authoritative — the VZ
    /// process lifecycle can outlive the dict.
    private func isDiskInUse(bundle: VirtualMachineBundle) -> Bool {
        let diskPath = bundle.url
            .appendingPathComponent(VirtualMachineBundle.diskImageFileName)
            .path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = [diskPath]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            // lsof exits non-zero with empty output when the
            // file is not open; non-empty output means at
            // least one process holds a handle.
            return !data.isEmpty &&
                (String(data: data, encoding: .utf8) ?? "").split(separator: "\n").count > 1
        } catch {
            // lsof unavailable — skip the pre-check and let
            // `DiskInjector` surface the raw error if the
            // attach fails.
            return false
        }
    }

    enum GuestToolsInstallError: LocalizedError {
        case vmRunning(String)
        case bundleMissing
        case diskInUse(String)
        case unsupportedGuestOS

        var errorDescription: String? {
            switch self {
            case .vmRunning(let name):
                "Stop '\(name)' before installing Guest Tools — disk injection requires the VM to be shut down."
            case .bundleMissing:
                "Spooktacular Guest Tools bundle not found alongside Spooktacular.app."
            case .diskInUse(let name):
                "'\(name)''s disk image is still in use by Apple's Virtualization XPC service, which lingers briefly after Stop."
            case .unsupportedGuestOS:
                "Spooktacular Guest Tools is macOS-only. Linux guests use spice-vdagent + distro-native tooling for the same functionality."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .vmRunning:
                "Click Stop, then retry Install Guest Tools."
            case .bundleMissing:
                "Rebuild the app with `./build-app.sh` — the script now bundles Spooktacular Guest Tools.app under Contents/Applications/."
            case .diskInUse:
                "Wait 5-10 seconds for the XPC service to release the disk, then retry. If it persists, Force Quit 'com.apple.Virtualization.VirtualMachine' in Activity Monitor."
            case .unsupportedGuestOS:
                "On a Linux guest, install spice-vdagent with your distro's package manager: `apt install spice-vdagent` (Debian/Ubuntu) or `dnf install spice-vdagent` (Fedora/RHEL)."
            }
        }
    }

    /// Errors from ``provisionGitHubRunnerForCreate(bundle:runnerSpec:displayName:cancellationTask:)``.
    ///
    /// Every case describes a failure that happens after the VM
    /// bundle already exists on disk — the recovery text always
    /// points at manual next steps rather than "recreate the VM,"
    /// matching the CLI's "the VM was created and has been kept"
    /// framing for a late runner-provisioning-phase failure.
    enum RunnerProvisioningError: LocalizedError {
        /// The bundled provisioner plist + runner script weren't
        /// found (a dev build that never ran `build-app.sh`).
        /// Zero-touch runner registration has nothing to fall back
        /// to without the daemon that executes the runner script.
        case provisionerAssetsNotFound
        /// ``AppState/startVM(_:recovery:guestProvisioning:)`` returned
        /// without the VM appearing in ``AppState/runningVMs``.
        case startFailed

        var errorDescription: String? {
            switch self {
            case .provisionerAssetsNotFound:
                "Provisioner plist/runner script not found — run build-app.sh to produce Resources/SpookProvisioner/."
            case .startFailed:
                "The VM failed to start after the runner script was injected."
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .provisionerAssetsNotFound:
                "Rebuild the app with ./build-app.sh, which bundles the provisioner plist and runner script."
            case .startFailed:
                "The runner script is injected. Try starting the VM manually from the sidebar."
            }
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
        clipboardStatuses.removeAll()
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
