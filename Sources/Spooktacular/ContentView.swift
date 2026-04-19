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
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var showInspector = false
    @State private var didRestoreWorkspaces = false

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
                appState.errorSuggestedAction = nil
            }
        } message: {
            VStack(alignment: .leading, spacing: 4) {
                if let message = appState.errorMessage {
                    Text(message)
                }
                if let hint = appState.errorSuggestedAction {
                    Text(hint).font(.caption)
                }
            }
        }
        .onAppear {
            appState.loadVMs()
            restorePreviouslyOpenWorkspaces()
        }
        .toolbarApplyingGlassContainer()
    }

    /// Re-opens workspace windows that were open at last quit.
    ///
    /// Guarded by a `@State` flag so re-appearing the library
    /// window does not re-open duplicates. ``AppState`` handles
    /// the case where a VM was deleted while closed — its
    /// ``AppState/restorableWorkspaceNames()`` silently skips
    /// missing entries.
    private func restorePreviouslyOpenWorkspaces() {
        guard !didRestoreWorkspaces else { return }
        didRestoreWorkspaces = true
        for name in appState.restorableWorkspaceNames() {
            openWindow(id: "workspace", value: name)
        }
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
///
/// # Long-value layout
///
/// Values that can exceed the inspector column width — UUIDs,
/// filesystem paths, long-form timestamps — render on a row *below*
/// their label using the `LabeledContent { content } label: { label }`
/// initializer. Apple's macOS HIG recommends putting the content on
/// its own row whenever the value is likely to wrap or truncate, so
/// the label/content alignment doesn't fight the inspector's
/// 280–400 pt column. Short atomic values (name, core counts,
/// booleans) keep the default trailing layout — they fit fine.
///
/// Docs:
/// - `LabeledContent` custom-label init:
///   https://developer.apple.com/documentation/swiftui/labeledcontent
/// - `inspectorColumnWidth(min:ideal:max:)`:
///   https://developer.apple.com/documentation/swiftui/view/inspectorcolumnwidth(min:ideal:max:)
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

            // UUID and timestamp both overflow the inspector's
            // 280–400 pt column. Render them on a line below the
            // label with `.lineLimit(nil)` so they wrap cleanly
            // rather than clip on the trailing edge. This is the
            // layout Apple uses in their own inspectors (e.g.
            // Finder's Info window) for paths and identifiers.
            stackedRow(
                label: "ID",
                accessibilityLabel: "VM identifier",
                accessibilityValue: bundle.metadata.id.uuidString
            ) {
                Text(bundle.metadata.id.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            stackedRow(
                label: "Created",
                accessibilityLabel: "Creation date"
            ) {
                Text(
                    bundle.metadata.createdAt,
                    format: .dateTime.month().day().year().hour().minute()
                )
                .font(.callout)
                .monospacedDigit()
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
            }

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
                    // Use the stacked variant — host paths are
                    // typically wider than the inspector's 400 pt
                    // maximum. Show the read-only/read-write chip
                    // inline with the tag so the relationship is
                    // obvious at a glance.
                    stackedRow(
                        label: LocalizedStringKey(folder.tag),
                        accessoryLabel: folder.readOnly ? "read-only" : "read-write",
                        accessibilityLabel: "Shared folder \(folder.tag)",
                        accessibilityValue: "\(folder.hostPath), \(folder.readOnly ? "read-only" : "read-write")"
                    ) {
                        Text(folder.hostPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
            // The bundle path is a full filesystem URL — always
            // wider than the inspector column. Stack + head/tail
            // truncation + `.help(...)` so the full path is
            // reachable on hover, matching Apple's Finder Info
            // window pattern for long paths.
            stackedRow(
                label: "Bundle",
                accessibilityLabel: "Bundle path",
                accessibilityValue: bundle.url.path
            ) {
                Text(bundle.url.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(bundle.url.path)
            }
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

    /// A vertically-stacked inspector row: label on top, content
    /// below, and an optional right-side accessory badge (e.g.
    /// "read-only"). Use this for values that exceed the
    /// inspector's narrow column: UUIDs, filesystem paths, long
    /// timestamps. The stacked form avoids the trailing-edge
    /// clipping that Apple's default `LabeledContent` layout
    /// produces when content is wider than the column minus the
    /// label's intrinsic size.
    ///
    /// Docs: https://developer.apple.com/documentation/swiftui/labeledcontent
    ///
    /// - Parameters:
    ///   - label: The row's leading label text.
    ///   - accessoryLabel: Optional trailing caption on the same
    ///     line as `label` (e.g. a "ro"/"rw" chip).
    ///   - accessibilityLabel: Describes the row for VoiceOver.
    ///   - accessibilityValue: Overrides the VoiceOver value.
    ///     Falls back to the rendered text when nil.
    ///   - content: The wrapping value block.
    @ViewBuilder
    private func stackedRow<Content: View>(
        label: LocalizedStringKey,
        accessoryLabel: String? = nil,
        accessibilityLabel: String,
        accessibilityValue: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent {
            EmptyView()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(label)
                        .foregroundStyle(.primary)
                    if let accessoryLabel {
                        Text(accessoryLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                content()
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
    }

}
