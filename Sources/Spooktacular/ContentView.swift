import SwiftUI
import SpooktacularKit

/// The main application content view.
///
/// Uses a `NavigationSplitView` with a searchable sidebar listing
/// VMs and a detail area showing the VM display or configuration.
/// An inspector panel slides out for VM details.
struct ContentView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @State private var showInspector = false

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            SidebarView(searchText: $searchText)
                .accessibilitySortPriority(3)
        } detail: {
            detailContent
                .accessibilitySortPriority(2)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: "Filter VMs"
        )
        .sheet(isPresented: $state.showCreateSheet) {
            CreateVMSheet()
        }
        .alert(
            "Error",
            isPresented: $state.errorPresented
        ) {
            Button("OK", role: .cancel) {
                appState.errorMessage = nil
            }
        } message: {
            if let message = appState.errorMessage {
                Text(message)
            }
        }
        .onAppear {
            appState.loadVMs()
        }
        .toolbarApplyingGlassContainer()
    }

    @ViewBuilder
    private var detailContent: some View {
        if let selected = appState.selectedVM,
           let bundle = appState.vms[selected] {
            WorkspacePreviewCard(name: selected, bundle: bundle)
                .inspector(isPresented: $showInspector) {
                    VMInspectorView(name: selected, bundle: bundle)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 400)
                        .accessibilitySortPriority(1)
                }
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button {
                            withAnimation(reduceMotion ? .none : .default) {
                                showInspector.toggle()
                            }
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .glassButton()
                        .help("Toggle inspector panel")
                        .accessibilityIdentifier(AccessibilityID.inspectorToggle)
                        .accessibilityHint("Shows or hides VM details")
                    }
                }
        } else {
            emptyState
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if appState.vms.isEmpty {
            EmptyStateView(onCreate: { appState.showCreateSheet = true })
                .accessibilityIdentifier(AccessibilityID.createVMButton)
        } else {
            ContentUnavailableView(
                "Select a VM",
                systemImage: "sidebar.left",
                description: Text("Choose a workspace from the sidebar.")
            )
        }
    }
}

// MARK: - Workspace Preview Card

/// The library's detail pane: a glass-chromed summary of the
/// selected VM with a prominent "Open Workspace" button.
///
/// Running VMs now live in their own windows (see
/// ``WorkspaceWindow``) — the library's job is discovery and
/// lifecycle orchestration, not hosting the framebuffer.
struct WorkspacePreviewCard: View {

    let name: String
    let bundle: VirtualMachineBundle

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            WorkspaceIconView(
                spec: bundle.metadata.iconSpec ?? .defaultSpec,
                size: 160
            )

            VStack(spacing: 6) {
                Text(name)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))

                HStack(spacing: 12) {
                    Label("\(bundle.spec.cpuCount) CPU", systemImage: "cpu")
                    Label("\(bundle.spec.memorySizeInGigabytes) GB", systemImage: "memorychip")
                    Label("\(bundle.spec.diskSizeInGigabytes) GB", systemImage: "internaldrive")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

                if appState.isRunning(name) {
                    Label("Running", systemImage: "circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .glassStatusBadge()
                }
            }

            HStack(spacing: 12) {
                Button {
                    openWindow(id: "workspace", value: name)
                } label: {
                    Label("Open Workspace", systemImage: "macwindow")
                        .font(.headline)
                        .padding(.horizontal, 8)
                }
                .glassButton()
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
                .help("Open this workspace in its own window")

                if appState.isRunning(name) {
                    Button {
                        Task { await appState.stopVM(name) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .padding(.horizontal, 4)
                    }
                    .glassButton()
                    .controlSize(.large)
                } else {
                    Button {
                        Task { await appState.startVM(name) }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .padding(.horizontal, 4)
                    }
                    .glassButton()
                    .controlSize(.large)
                    .tint(.green)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Inspector panel showing VM configuration details.
///
/// Mirrors the detail config view in a compact Form layout using
/// `LabeledContent` and `.formStyle(.grouped)`. Shows all configured
/// options: identity, hardware, display, network, audio, shared
/// folders, provisioning, and storage.
struct VMInspectorView: View {

    let name: String
    let bundle: VirtualMachineBundle

    var body: some View {
        Form {
            identitySection
            hardwareSection
            displaySection
            networkSection
            audioSection
            sharedFoldersSection
            storageSection
        }
        .formStyle(.grouped)
    }

    // MARK: - Identity

    @ViewBuilder
    private var identitySection: some View {
        Section("Identity") {
            LabeledContent("Name", value: name)
                .accessibilityElement(children: .combine)

            LabeledContent("ID") {
                Text(bundle.metadata.id.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .accessibilityLabel("VM identifier")
            .accessibilityValue(bundle.metadata.id.uuidString)

            LabeledContent("Created") {
                Text(
                    bundle.metadata.createdAt,
                    format: .dateTime.month().day().year().hour().minute()
                )
            }
            .accessibilityElement(children: .combine)

            LabeledContent("Setup") {
                Image(systemName: bundle.metadata.setupCompleted
                      ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(
                    bundle.metadata.setupCompleted ? .green : .secondary
                )
            }
            .accessibilityLabel("Setup status")
            .accessibilityValue(
                bundle.metadata.setupCompleted ? "Complete" : "Pending"
            )
        }
    }

    // MARK: - Hardware

    @ViewBuilder
    private var hardwareSection: some View {
        Section("Hardware") {
            LabeledContent("CPU", value: "\(bundle.spec.cpuCount) cores")
                .accessibilityElement(children: .combine)
            LabeledContent("Memory", value: "\(bundle.spec.memorySizeInGigabytes) GB")
                .accessibilityElement(children: .combine)
            LabeledContent("Disk", value: "\(bundle.spec.diskSizeInGigabytes) GB")
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Display

    @ViewBuilder
    private var displaySection: some View {
        Section("Display") {
            LabeledContent("Monitors", value: "\(bundle.spec.displayCount)")
                .accessibilityElement(children: .combine)
            booleanRow(
                "Auto-resize",
                enabled: bundle.spec.autoResizeDisplay,
                accessibilityLabel: "Auto-resize display"
            )
        }
    }

    // MARK: - Network

    @ViewBuilder
    private var networkSection: some View {
        Section("Network") {
            LabeledContent("Mode", value: bundle.spec.networkMode.serialized)
                .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Audio

    @ViewBuilder
    private var audioSection: some View {
        Section("Audio") {
            booleanRow(
                "Speaker",
                enabled: bundle.spec.audioEnabled,
                accessibilityLabel: "Speaker output"
            )
            booleanRow(
                "Microphone",
                enabled: bundle.spec.microphoneEnabled,
                accessibilityLabel: "Microphone input"
            )
            booleanRow(
                "Clipboard",
                enabled: bundle.spec.clipboardSharingEnabled,
                accessibilityLabel: "Clipboard sharing"
            )
        }
    }

    // MARK: - Shared Folders

    @ViewBuilder
    private var sharedFoldersSection: some View {
        Section("Shared Folders") {
            if bundle.spec.sharedFolders.isEmpty {
                Text("None configured")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .accessibilityLabel("No shared folders configured")
            } else {
                ForEach(bundle.spec.sharedFolders, id: \.tag) { folder in
                    LabeledContent(folder.tag) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(folder.hostPath)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text(folder.readOnly ? "read-only" : "read-write")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
            LabeledContent("Bundle") {
                Text(bundle.url.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .accessibilityLabel("Bundle path")
            .accessibilityValue(bundle.url.path)
        }
    }

    // MARK: - Helpers

    private func booleanRow(
        _ label: String,
        enabled: Bool,
        accessibilityLabel: String
    ) -> some View {
        LabeledContent(label) {
            Image(systemName: enabled
                  ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(enabled ? .green : .secondary)
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(enabled ? "Enabled" : "Disabled")
    }

}
