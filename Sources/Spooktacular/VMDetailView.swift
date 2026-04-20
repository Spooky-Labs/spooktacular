import SwiftUI
import SpooktacularKit
@preconcurrency import Virtualization

/// Detail view for a selected VM. Simple stack: icon, name,
/// specs, primary + secondary actions.
struct VMDetailView: View {

    let name: String
    let bundle: VirtualMachineBundle

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var isRunning: Bool { appState.isRunning(name) }

    @State private var stats = WorkspaceStatsModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroPane
                if isRunning { statsPane }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .task(id: "\(name)-\(isRunning)") {
            // Route stats through the Apple-native
            // `VZVirtioSocketListener` the VM exposes via
            // `agentEventListener()`. The RPC client stays
            // wired for host-observable probes (latency, port
            // count).
            if isRunning,
               let client = appState.agentClients[name],
               let listener = appState.runningVMs[name]?.agentEventListener() {
                stats.start(listener: listener, client: client)
            } else {
                stats.stop()
            }
        }
    }

    // MARK: - Hero

    private var heroPane: some View {
        VStack(spacing: 20) {
            // Use the VM's own rendered icon (same visual the
            // workspace-window stopped state shows) instead of a
            // generic SF Symbol — keeps the library and workspace
            // visually consistent and lets the custom `iconSpec`
            // in the bundle metadata carry identity across both
            // surfaces.
            WorkspaceIconView(
                spec: bundle.metadata.iconSpec ?? .defaultSpec,
                size: 140
            )
            .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(name)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text("\(bundle.spec.cpuCount) CPU · \(bundle.spec.memorySizeInGigabytes) GB RAM · \(bundle.spec.diskSizeInGigabytes) GB disk")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                statusPill
            }

            // Wrap the action row in a `GlassEffectContainer` so
            // the prominent + secondary buttons share one glass
            // pane and morph smoothly when Start/Suspend/Stop
            // swap in and out. `spacing: 8` is slightly larger
            // than the `HStack`'s 12 so adjacent buttons blend
            // at the capsule edges under the pointer.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        openWindow(id: "workspace", value: name)
                    } label: {
                        Label("Open Workspace", systemImage: "macwindow")
                            .padding(.horizontal, 8)
                    }
                    .glassProminentButton()
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])

                    let transitioning = appState.transitioningVMs.contains(name)
                    let suspended = !isRunning && appState.isSuspended(name)
                    if isRunning {
                        Button {
                            Task { await appState.suspendVM(name) }
                        } label: {
                            if transitioning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Suspend", systemImage: "pause.fill")
                            }
                        }
                        .glassButton()
                        .controlSize(.large)
                        .disabled(transitioning)
                        .help("Save VM state and quit. Next start picks up exactly where you left off.")

                        Button {
                            Task { await appState.stopVM(name) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .glassButton()
                        .controlSize(.large)
                        .disabled(transitioning)
                    } else {
                        Button {
                            Task { await appState.startVM(name) }
                        } label: {
                            if transitioning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label(
                                    suspended ? "Resume" : "Start",
                                    systemImage: suspended ? "play.rectangle.fill" : "play.fill"
                                )
                            }
                        }
                        .glassButton()
                        .controlSize(.large)
                        .tint(.green)
                        .disabled(transitioning)
                        .help(suspended
                            ? "Restore from the saved state and continue."
                            : "Cold-boot the VM.")

                        // Only macOS guests can host the
                        // Darwin agent. `DiskInjector` also
                        // requires APFS — Linux guests use
                        // ext4/btrfs/xfs and wouldn't survive
                        // the mount step. Linux VMs get the
                        // Spooktacular Linux agent via the
                        // separate `LinuxAgent/` SwiftPM
                        // package inside the guest.
                        if bundle.spec.guestOS == .macOS {
                            Button {
                                appState.installGuestAgent(name)
                            } label: {
                                if transitioning {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Install Agent", systemImage: "arrow.down.circle")
                                }
                            }
                            .glassButton()
                            .controlSize(.large)
                            .disabled(transitioning)
                            .help("Disk-inject the guest agent so the live-metrics chart will populate on next start. Idempotent — safe to click multiple times.")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 24)
    }

    /// Tinted Liquid Glass pill showing the current lifecycle
    /// state.
    ///
    /// Only the leading glyph carries the bright semantic color
    /// (green dot = running, orange pause-circle = suspended);
    /// the text stays default foreground so it reads cleanly
    /// against the tinted glass background. This matches the
    /// HIG's "color carries meaning once, text stays neutral"
    /// pattern and avoids the previous "whole pill is neon
    /// green" look.
    @ViewBuilder
    private var statusPill: some View {
        if isRunning {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Running")
                    .font(.caption.weight(.semibold))
            }
            .glassStatusPill()
            .padding(.top, 4)
        } else if appState.isSuspended(name) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Suspended")
                    .font(.caption.weight(.semibold))
            }
            .glassStatusPill()
            .padding(.top, 4)
        }
    }

    // MARK: - Live stats (Swift Charts)

    private var statsPane: some View {
        WorkspaceStatsSidebar(model: stats)
            .frame(maxWidth: .infinity)
    }
}

/// `NSViewRepresentable` wrapping `VZVirtualMachineView` so a
/// running VM's framebuffer can be hosted inside a SwiftUI view.
/// Used by `WorkspaceWindow` when the VM is running.
struct VMDisplayView: NSViewRepresentable {

    let name: String
    let virtualMachine: VirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine.vzVM
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.setAccessibilityLabel("Virtual machine display for \(name)")
        view.setAccessibilityRole(.group)
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = virtualMachine.vzVM
    }
}

/// Detail view for a selected image in the Images section.
/// Shows the image's name, source (local IPSW / OCI reference),
/// size, and a context-menu-equivalent set of actions.
struct ImageDetailView: View {

    let image: VirtualMachineImage
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "photo.stack")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text(image.name).font(.largeTitle.weight(.semibold))

                Text(sourceLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let bytes = image.sizeInBytes {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 12) {
                    Button {
                        // Pre-seed the Create sheet's local IPSW
                        // path so it opens already pointing at
                        // this image — no re-browse needed. Works
                        // only for local-IPSW images; OCI refs
                        // fall through to Apple's default
                        // download path.
                        if case .ipsw(let path) = image.source {
                            appState.pendingCreateIpswPath = path
                        }
                        appState.showCreateSheet = true
                    } label: {
                        Label("Create VM from image", systemImage: "plus.square.on.square")
                            .padding(.horizontal, 8)
                    }
                    .glassProminentButton()
                    .controlSize(.large)

                    Button(role: .destructive) {
                        try? appState.imageLibrary.remove(id: image.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .glassButton()
                    .controlSize(.large)
                }
            }

            Spacer()
        }
        .frame(maxWidth: 560)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(image.name)
    }

    private var sourceLabel: String {
        switch image.source {
        case .ipsw(let path):
            return "Local IPSW · \((path as NSString).lastPathComponent)"
        case .oci(let reference):
            return "OCI · \(reference)"
        }
    }
}

/// Sidebar row for one VM — name, specs, running dot.
struct VMRow: View {

    let name: String
    @Environment(AppState.self) private var appState

    private var isRunning: Bool { appState.isRunning(name) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(isRunning ? .green : .secondary.opacity(0.3))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                if let bundle = appState.vms[name] {
                    Text("\(bundle.spec.cpuCount) CPU · \(bundle.spec.memorySizeInGigabytes) GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
