import SwiftUI
import SpooktacularKit

/// The sidebar listing VMs and cached images.
struct SidebarView: View {

    @Environment(AppState.self) private var appState

    @Binding var searchText: String
    @State private var confirmDelete: String?

    var body: some View {
        @Bindable var state = appState

        List(selection: $state.selectedVM) {
            // VM section
            Section("Virtual Machines") {
                ForEach(filteredVMNames, id: \.self) { name in
                    VMRow(name: name)
                        .tag(name)
                        .accessibilityIdentifier(AccessibilityID.vmRow(name))
                        .contextMenu { vmContextMenu(for: name) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                confirmDelete = name
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }

            // Image library section
            Section("Images") {
                ForEach(appState.imageLibrary.images) { image in
                    ImageRow(image: image)
                }

                Button {
                    appState.showAddImage = true
                } label: {
                    Label("Add Image…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.vmList)
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.showCreateSheet = true
                } label: {
                    Label("Create VM", systemImage: "plus.square.on.square")
                }
                .glassButton()
                .help("Create a new virtual machine")
                .accessibilityIdentifier(AccessibilityID.createVMButton)
            }
        }
        .overlay {
            if filteredVMNames.isEmpty && !searchText.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .alert("Delete VM?", isPresented: showDeleteAlert) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let name = confirmDelete {
                    appState.deleteVM(name)
                    confirmDelete = nil
                }
            }
        } message: {
            if let name = confirmDelete {
                Text("'\(name)' and all its data will be permanently deleted.")
            }
        }
    }

    // MARK: - Filtering

    private var filteredVMNames: [String] {
        let sorted = appState.vms.keys.sorted()
        if searchText.isEmpty { return sorted }
        return sorted.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var showDeleteAlert: Binding<Bool> {
        Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )
    }

    @ViewBuilder
    private func vmContextMenu(for name: String) -> some View {
        OpenWorkspaceButton(vmName: name)
        Divider()
        if appState.isRunning(name) {
            Button("Stop", systemImage: "stop.fill") {
                Task { await appState.stopVM(name) }
            }
        } else {
            Button("Start", systemImage: "play.fill") {
                Task { await appState.startVM(name) }
            }
        }
        Divider()
        Button("Clone", systemImage: "doc.on.doc") {
            appState.cloneVM(name, to: "\(name)-clone")
        }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) {
            confirmDelete = name
        }
    }
}

// MARK: - Open Workspace Button

/// Button that opens a dedicated workspace window via the SwiftUI
/// `openWindow` environment value. Extracted so both the sidebar
/// context menu and the detail pane can reuse it.
struct OpenWorkspaceButton: View {
    let vmName: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Workspace", systemImage: "macwindow") {
            openWindow(id: "workspace", value: vmName)
        }
    }
}

// MARK: - VM Row

struct VMRow: View {

    let name: String
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var agentConnected: Bool?

    private var isRunning: Bool { appState.isRunning(name) }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isRunning
                  ? (differentiateWithoutColor ? "play.circle.fill" : "circle.fill")
                  : (differentiateWithoutColor ? "stop.circle" : "circle.fill"))
                .foregroundStyle(isRunning ? .green : .secondary.opacity(0.3))
                .font(.system(size: 8))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let bundle = appState.vms[name] {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu").font(.caption2)
                        Text("\(bundle.spec.cpuCount)")
                        Image(systemName: "memorychip").font(.caption2)
                        Text("\(bundle.spec.memorySizeInGigabytes)G")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isRunning {
                HStack(spacing: 6) {
                    if let connected = agentConnected {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(connected ? .green : .yellow)
                            .accessibilityLabel(connected ? "Agent connected" : "Agent checking")
                    }

                    Text("Running")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                }
                .glassStatusBadge()
            }
        }
        .padding(.vertical, 3)
        // Group the icon + name + specs into a single VoiceOver
        // element with a dynamic label + value, per Apple's
        // accessibility guidance: label describes *what*, value
        // describes the *current state*.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Virtual machine \(name)"))
        .accessibilityValue(Text(accessibilityValueString))
        .task(id: isRunning) {
            guard isRunning else { agentConnected = nil; return }
            guard let client = appState.agentClients[name] else {
                agentConnected = false
                return
            }
            while !Task.isCancelled {
                do {
                    _ = try await client.health()
                    agentConnected = true
                } catch {
                    agentConnected = false
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Dynamic VoiceOver value — includes current status, hardware,
    /// and agent connectivity so the user hears the full state in
    /// one pass.
    private var accessibilityValueString: String {
        var parts: [String] = [isRunning ? "running" : "stopped"]
        if let bundle = appState.vms[name] {
            parts.append("\(bundle.spec.cpuCount) cores")
            parts.append("\(bundle.spec.memorySizeInGigabytes) GB RAM")
        }
        if let connected = agentConnected {
            parts.append(connected ? "agent connected" : "agent not connected")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Image Row

struct ImageRow: View {

    let image: VirtualMachineImage

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: imageIcon)
                .foregroundStyle(.blue)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(image.name)
                    .font(.body)
                    .lineLimit(1)

                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let size = image.sizeInBytes {
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(size),
                    countStyle: .file
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var imageIcon: String {
        switch image.source {
        case .ipsw: "opticaldisc"
        case .oci: "shippingbox"
        }
    }

    private var sourceLabel: String {
        switch image.source {
        case .ipsw(let path):
            URL(filePath: path).lastPathComponent
        case .oci(let ref):
            ref
        }
    }
}
