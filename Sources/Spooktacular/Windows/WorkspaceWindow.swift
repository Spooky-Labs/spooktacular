import SwiftUI
@preconcurrency import Virtualization
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
        .task(id: vmName) {
            await appState.workspaceDidOpen(vmName)
        }
        .onDisappear {
            appState.workspaceDidClose(vmName)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for bundle: VirtualMachineBundle) -> some View {
        if let vm = appState.runningVMs[vmName] {
            VMDisplayView(name: vmName, virtualMachine: vm)
                .ignoresSafeArea()
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
        }
    }

    @ToolbarContentBuilder
    private var stoppedToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await appState.startVM(vmName) }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .glassButton()
            .tint(.green)
            .help("Start this workspace")
            .accessibilityIdentifier(AccessibilityID.startButton)
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
        .glassCard(cornerRadius: 24)
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
