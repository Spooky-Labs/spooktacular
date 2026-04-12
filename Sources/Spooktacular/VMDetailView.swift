import SwiftUI
import Virtualization
import SpooktacularKit

/// The detail view for a selected VM.
///
/// When running: shows the live VM display (VZVirtualMachineView).
/// When stopped: shows a launch screen with a prominent Start
/// button and a quick summary. The full configuration is in the
/// inspector panel — not duplicated here.
struct VMDetailView: View {

    let name: String
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let vm = appState.runningVMs[name] {
                VMDisplayView(name: name, virtualMachine: vm)
            } else if let bundle = appState.vms[name] {
                VMLaunchView(name: name, bundle: bundle)
            }
        }
        .toolbar {
            toolbarContent
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if appState.isRunning(name) {
                Button {
                    Task { await appState.stopVM(name) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Stop the virtual machine")
                .accessibilityIdentifier(AccessibilityID.stopButton)
                .accessibilityHint("Force stops the virtual machine")
            } else {
                Button {
                    Task { await appState.startVM(name) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .help("Start the virtual machine")
                .accessibilityIdentifier(AccessibilityID.startButton)
                .accessibilityHint("Boots the virtual machine")
                .tint(.green)
            }
        }
    }
}

// MARK: - VM Display (Running)

/// Wraps `VZVirtualMachineView` for SwiftUI.
struct VMDisplayView: NSViewRepresentable {

    let name: String
    let virtualMachine: VirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine.vzVM
        view.capturesSystemKeys = true
        if #available(macOS 14.0, *) {
            view.automaticallyReconfiguresDisplay = true
        }
        view.setAccessibilityLabel("Virtual machine display for \(name)")
        view.setAccessibilityRole(.group)
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        nsView.virtualMachine = virtualMachine.vzVM
    }
}

// MARK: - VM Launch Screen (Stopped)

/// A centered launch screen shown when the VM is stopped.
///
/// Shows the VM name, status badge, a quick hardware summary,
/// and a prominent Start button. The full configuration lives
/// in the inspector panel — this view is intentionally minimal
/// to avoid duplicating the inspector's content.
struct VMLaunchView: View {

    let name: String
    let bundle: VMBundle
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            Image(systemName: "desktopcomputer")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            // Name + status
            VStack(spacing: 6) {
                Text(name)
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                    .accessibilityAddTraits(.isHeader)

                Label(
                    bundle.metadata.setupCompleted
                        ? "Ready" : "Setup pending",
                    systemImage: bundle.metadata.setupCompleted
                        ? "checkmark.circle.fill" : "clock"
                )
                .font(.subheadline)
                .foregroundStyle(
                    bundle.metadata.setupCompleted ? .green : .orange
                )
            }

            // Quick spec summary (one line)
            let memGB = bundle.spec.memorySizeInBytes / (1024 * 1024 * 1024)
            let diskGB = bundle.spec.diskSizeInBytes / (1024 * 1024 * 1024)
            HStack(spacing: 16) {
                Label("\(bundle.spec.cpuCount) cores", systemImage: "cpu")
                Label("\(memGB) GB", systemImage: "memorychip")
                Label("\(diskGB) GB", systemImage: "internaldrive")
                Label(
                    "\(bundle.spec.displayCount)",
                    systemImage: "display"
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            // Start button
            Button {
                Task { await appState.startVM(name) }
            } label: {
                Label("Start Virtual Machine", systemImage: "play.fill")
                    .font(.title3)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
            }
            .modifier(GlassButtonModifier())
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.startButton)
            .accessibilityHint("Boots the virtual machine")

            // Hint about inspector
            Text("Open the inspector panel for full configuration details.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
