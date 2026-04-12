import SwiftUI
import SpooktacularKit

/// The sidebar listing VMs and cached images.
struct SidebarView: View {

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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

// MARK: - VM Row

struct VMRow: View {

    let name: String
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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
                    let memoryInGigabytes = bundle.spec.memorySizeInBytes / (1024 * 1024 * 1024)
                    HStack(spacing: 4) {
                        Image(systemName: "cpu").font(.caption2)
                        Text("\(bundle.spec.cpuCount)")
                        Image(systemName: "memorychip").font(.caption2)
                        Text("\(memoryInGigabytes)G")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isRunning {
                Text("Running")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.1), in: Capsule())
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [name]
        parts.append(isRunning ? "running" : "stopped")
        if let bundle = appState.vms[name] {
            let memoryInGigabytes = bundle.spec.memorySizeInBytes / (1024 * 1024 * 1024)
            parts.append("\(bundle.spec.cpuCount) CPU cores")
            parts.append("\(memoryInGigabytes) gigabytes memory")
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
            URL(fileURLWithPath: path).lastPathComponent
        case .oci(let ref):
            ref
        }
    }
}
