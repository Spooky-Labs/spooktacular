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
            if isRunning, let client = appState.agentClients[name] {
                stats.start(client: client)
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

                if isRunning {
                    Label("Running", systemImage: "circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.top, 4)
                }
            }

            HStack(spacing: 12) {
                Button {
                    openWindow(id: "workspace", value: name)
                } label: {
                    Label("Open Workspace", systemImage: "macwindow")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
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
                    .controlSize(.large)
                    .disabled(transitioning)
                    .help("Save VM state and quit. Next start picks up exactly where you left off.")

                    Button {
                        Task { await appState.stopVM(name) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
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
                    .controlSize(.large)
                    .tint(.green)
                    .disabled(transitioning)
                    .help(suspended
                        ? "Restore from the saved state and continue."
                        : "Cold-boot the VM.")
                }
            }
        }
        .padding(.vertical, 24)
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

            HStack(spacing: 12) {
                Button {
                    // Pre-seed the Create sheet's local IPSW
                    // path so it opens already pointing at this
                    // image — no re-browse needed. Works only
                    // for local-IPSW images; OCI refs fall
                    // through to the default Apple-download path.
                    if case .ipsw(let path) = image.source {
                        appState.pendingCreateIpswPath = path
                    }
                    appState.showCreateSheet = true
                } label: {
                    Label("Create VM from image", systemImage: "plus.square.on.square")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    try? appState.imageLibrary.remove(id: image.id)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .controlSize(.large)
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
