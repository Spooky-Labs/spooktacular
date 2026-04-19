import AppKit
import SwiftUI
@preconcurrency import Virtualization
import SpookInfrastructureApple
import SpooktacularKit

/// A window dedicated to a single VM workspace.
///
/// Each running VM gets its own `WorkspaceWindow` — separate from
/// the library window — so users can close the library and keep
/// their workspaces open, matching the "VMs-are-apps" mental model
/// pioneered by GhostVM. The window hosts a live
/// ``VZVirtualMachineView`` plus a Liquid-Glass toolbar and
/// receives focus-change callbacks that drive the Dock tile
/// coordinator.
///
/// The window is opened via
/// `openWindow(id: "workspace", value: vmName)` from any other
/// scene. SwiftUI handles window uniqueness by value — requesting
/// the same VM name twice brings the existing window forward
/// instead of creating a duplicate.
struct WorkspaceWindow: View {

    /// The VM this window represents, passed as the window's
    /// presented value. Keyed by name (the library's identifier).
    let vmName: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showSnapshots: Bool = false
    @State private var showHardware: Bool = false
    @State private var showPorts: Bool = false

    /// Holds the most-recently-resolved IP for two seconds so the
    /// toolbar "Copy IP" button can briefly flip to a checkmark
    /// after a successful copy — then reverts to the default
    /// label. A plain `@State Bool` wouldn't distinguish "just
    /// copied 10.1.2.3" from "just copied 10.1.2.4", which
    /// matters when the user re-resolves and the VM's DHCP
    /// lease has rotated.
    @State private var lastCopiedIP: String?

    var body: some View {
        Group {
            if let bundle = appState.vms[vmName] {
                content(for: bundle)
            } else {
                missingWorkspace
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle(vmName)
        // Window-wide Liquid Glass / material background. On
        // macOS 26 this becomes the Liquid Glass container;
        // 14 and 15 fall back to `ultraThinMaterial` via the
        // helper in `GlassModifiers.swift`. Keeps the
        // workspace chrome consistent with the library window.
        .windowGlassBackground()
        // Wraps the toolbar in a shared material layer on
        // macOS 26+ so the primary-action button cluster
        // (Stop / Snapshots / Ports / Copy IP — or Start /
        // Hardware / Snapshots) renders as one continuous
        // glass shape rather than N separate blurs.
        //
        // Docs: https://developer.apple.com/documentation/swiftui/view/toolbarbackgroundvisibility(_:for:)
        .toolbarApplyingGlassContainer()
        .task(id: vmName) {
            await appState.workspaceDidOpen(vmName)
        }
        .onDisappear {
            appState.workspaceDidClose(vmName)
        }
        .sheet(isPresented: $showSnapshots) {
            SnapshotInspector(vmName: vmName)
                .environment(appState)
        }
        .sheet(isPresented: $showHardware) {
            HardwareEditor(vmName: vmName)
                .environment(appState)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for bundle: VirtualMachineBundle) -> some View {
        if let vm = appState.runningVMs[vmName] {
            // No `.ignoresSafeArea()` here — the previous
            // revision let the VZVirtualMachineView extend under
            // the window's title bar + toolbar, which clipped
            // the top row of the guest's menu bar and display
            // pixels on every workspace window. Apple's safe
            // area on macOS is exactly the window's content
            // inset region; honouring it keeps the guest
            // display below the chrome.
            //
            // Docs: https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)
            VMDisplayView(name: vmName, virtualMachine: vm)
                .toolbar { runningToolbar }
        } else {
            WorkspaceLaunchView(name: vmName, bundle: bundle)
                .toolbar { stoppedToolbar }
        }
    }

    @ViewBuilder
    private var missingWorkspace: some View {
        ContentUnavailableView(
            "Workspace Unavailable",
            systemImage: "questionmark.folder",
            description: Text("The VM '\(vmName)' was removed or is not loaded.")
        )
        .padding()
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var runningToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await appState.stopVM(vmName) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .glassButton()
            .help("Stop this workspace")
            .accessibilityIdentifier(AccessibilityID.stopButton)

            Button {
                showSnapshots = true
            } label: {
                Label("Snapshots", systemImage: "clock.arrow.circlepath")
            }
            .glassButton()
            .help("Manage snapshots for this workspace (⇧⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .shift])

            Button {
                showPorts.toggle()
            } label: {
                Label("Ports", systemImage: "network")
            }
            .glassButton()
            .help("See listening ports inside the workspace (⇧⌘P)")
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .popover(isPresented: $showPorts, arrowEdge: .bottom) {
                PortPanel(monitor: appState.portMonitor(for: vmName))
            }

            // Network actions grouped under a Menu: primary tap
            // copies the IP (the most frequent action); the
            // chevron exposes `SSH in Terminal…` (mirrors
            // `spook ssh <vm>`). Packaging both behind a single
            // toolbar slot keeps the chrome tight — the toolbar
            // already has Stop / Snapshots / Ports alongside —
            // and matches Apple's own "split-button" pattern.
            // Docs: https://developer.apple.com/documentation/swiftui/menu
            Menu {
                Button {
                    Task { await launchSSH() }
                } label: {
                    Label("SSH in Terminal…", systemImage: "terminal")
                }
                .help("Resolve the workspace's IP and open an ssh session in Terminal.app.")
            } label: {
                Label(
                    lastCopiedIP ?? "Copy IP",
                    systemImage: lastCopiedIP != nil ? "checkmark.circle.fill" : "number"
                )
            } primaryAction: {
                Task { await resolveAndCopyIP() }
            }
            .glassButton()
            .help("Resolve this workspace's IPv4 address. Tap to copy it; chevron for other network actions.")
            .accessibilityLabel(
                lastCopiedIP.map { "Copied \($0)" } ?? "Workspace network actions"
            )
            // Subtle transition when the label swaps between
            // "Copy IP" and the resolved address — matches the
            // pulse indicator pattern elsewhere in the toolbar.
            .animation(.smooth(duration: 0.2), value: lastCopiedIP)
        }
    }

    /// Resolves the running VM's IPv4 address from its MAC via
    /// `IPResolver` (DHCP lease table + ARP fallback — same path
    /// as `spook ip <vm>`) and copies the result to the general
    /// pasteboard.
    ///
    /// Intentionally idempotent: a second tap re-resolves in case
    /// the guest's DHCP lease has rotated since the last call.
    /// The toolbar label flips to a checkmark for two seconds so
    /// the user sees confirmation without a modal toast.
    ///
    /// `NSPasteboard.general` docs:
    /// https://developer.apple.com/documentation/appkit/nspasteboard/general
    private func resolveAndCopyIP() async {
        guard let mac = appState.vms[vmName]?.spec.macAddress else { return }
        do {
            guard let ip = try await IPResolver.resolveIP(macAddress: mac) else {
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ip, forType: .string)
            lastCopiedIP = ip
            // Revert the label after a brief confirmation window.
            // Checking `lastCopiedIP == ip` means a later copy
            // with a different IP (rotated DHCP lease) doesn't
            // accidentally erase its own confirmation.
            try? await Task.sleep(for: .seconds(2))
            if lastCopiedIP == ip { lastCopiedIP = nil }
        } catch {
            // Resolution failure is silent — the button simply
            // doesn't flip to the checkmark, and the user can
            // try again. Surfacing an error toast here would be
            // noisier than useful (DHCP + ARP both fail within
            // the first ~15s of a cold boot).
            Log.vm.debug("IP resolution failed for \(vmName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves the running VM's IPv4 address and opens the host's
    /// default ssh:// handler — mirrors `spook ssh <vm>` for users
    /// who live in the GUI. Terminal.app registers itself as the
    /// default handler on stock macOS, but iTerm2/Warp/etc. all
    /// register too, so this honours the user's chosen terminal.
    ///
    /// Uses defaults of `admin` + `~/.ssh/id_*` — the same as
    /// `spook ssh`. For non-default users or explicit key paths,
    /// the CLI's `--user` and `--key` flags remain the escape
    /// hatch; adding fields to a toolbar popover would bloat the
    /// 95%-case one-tap flow.
    ///
    /// `NSWorkspace.open(_:)` docs:
    /// https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)
    private func launchSSH() async {
        guard let mac = appState.vms[vmName]?.spec.macAddress else { return }
        do {
            guard let ip = try await IPResolver.resolveIP(macAddress: mac),
                  let url = URL(string: "ssh://admin@\(ip)") else {
                return
            }
            // `open(_:)` returns false only when no handler is
            // registered for the URL scheme, which on macOS is
            // effectively never for `ssh://`. We log the edge
            // case for support diagnostics rather than surfacing
            // a toast.
            if !NSWorkspace.shared.open(url) {
                Log.vm.debug("No handler registered for ssh:// scheme on this host.")
            }
        } catch {
            Log.vm.debug("SSH launch failed for \(vmName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @ToolbarContentBuilder
    private var stoppedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Start button with a split-menu affordance: primary
            // tap performs a normal boot; the chevron exposes
            // `Start in Recovery Mode`, which boots the guest
            // into macOS Recovery via
            // `VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery`.
            // SwiftUI's `Menu(primaryAction:)` renders exactly
            // this split-button shape on macOS 14+ per
            // https://developer.apple.com/documentation/swiftui/menu.
            Menu {
                Button {
                    Task { await appState.startVM(vmName, recovery: true) }
                } label: {
                    Label("Start in Recovery Mode", systemImage: "wrench.and.screwdriver")
                }
                .help("Boot into macOS Recovery (Disk Utility, Startup Security Utility, reinstall).")
            } label: {
                Label("Start", systemImage: "play.fill")
            } primaryAction: {
                Task { await appState.startVM(vmName) }
            }
            .glassButton()
            .tint(.green)
            .help("Start this workspace. Hold the chevron for Recovery-mode boot.")
            .accessibilityIdentifier(AccessibilityID.startButton)

            Button {
                showHardware = true
            } label: {
                Label("Hardware", systemImage: "cpu")
            }
            .glassButton()
            .help("Edit CPU, memory, and disk (⇧⌘H)")
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button {
                showSnapshots = true
            } label: {
                Label("Snapshots", systemImage: "clock.arrow.circlepath")
            }
            .glassButton()
            .help("Manage snapshots for this workspace (⇧⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Launch view

/// Glass-chromed landing view when a workspace is not running.
///
/// Shown when the user opens a workspace window for a stopped VM —
/// think of it as the workspace's idle state. A prominent start
/// button, a spec summary, and the workspace's custom icon.
struct WorkspaceLaunchView: View {

    let name: String
    let bundle: VirtualMachineBundle

    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            WorkspaceIconView(spec: bundle.metadata.iconSpec ?? .defaultSpec, size: 140)

            VStack(spacing: 6) {
                Text(name)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text(specSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Button {
                Task { await appState.startVM(name) }
            } label: {
                Label("Start Workspace", systemImage: "play.fill")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
            .glassButton()
            .tint(.green)
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.startButton)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No outer `.glassCard` here: the enclosing window
        // already carries a Liquid Glass / ultraThinMaterial
        // background (via `windowGlassBackground()` on the
        // workspace window root). Stacking `.glassCard` on top
        // produced double-chrome — a visible rectangle on a
        // window that was already translucent. Apple's
        // "Adopting Liquid Glass" guide explicitly warns
        // against nesting glass materials inside other glass
        // materials; keep the container plain and let the
        // window chrome carry the texture.
        //
        // Docs: https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
        .padding(24)
    }

    private var specSummary: String {
        let cpu = bundle.spec.cpuCount
        let mem = bundle.spec.memorySizeInGigabytes
        let disk = bundle.spec.diskSizeInGigabytes
        return "\(cpu) CPU · \(mem) GB RAM · \(disk) GB disk"
    }
}

// MARK: - Icon view

/// Renders an ``IconSpec`` as SwiftUI content by routing through
/// ``WorkspaceIconRenderer``. Used in the workspace launch view,
/// library cards, and the settings icon picker.
struct WorkspaceIconView: View {
    let spec: IconSpec
    let size: CGFloat

    var body: some View {
        Image(nsImage: WorkspaceIconRenderer.render(spec, size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Workspace icon")
    }
}
