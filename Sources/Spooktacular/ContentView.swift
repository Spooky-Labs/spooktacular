import SwiftUI
import SpooktacularKit

/// Library window — pure `NavigationSplitView`. Sidebar on the
/// left, detail on the right. No custom chrome, no overrides.
struct ContentView: View {

    @Environment(AppState.self) private var appState

    @State private var selection: SidebarSelection?
    @State private var searchText = ""
    @State private var didLoad = false

    /// Typed selection so a single `List(selection:)` can route
    /// clicks from two heterogeneous sections (VMs + Images) into
    /// one binding. Without this, images wouldn't participate in
    /// the selection system and clicks on them would be inert.
    enum SidebarSelection: Hashable {
        case vm(String)
        case image(UUID)
    }

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showCreateSheet = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
                .help("New Virtual Machine (⌘N)")
            }
        }
        .sheet(isPresented: $state.showCreateSheet) { CreateVMSheet() }
        .sheet(isPresented: $state.showAddImage) {
            AddImageSheet().environment(appState)
        }
        .alert("Error", isPresented: $state.errorPresented) {
            Button("OK", role: .cancel) {
                appState.errorMessage = nil
                appState.errorSuggestedAction = nil
            }
        } message: {
            if let message = appState.errorMessage { Text(message) }
        }
        .task {
            guard !didLoad else { return }
            didLoad = true
            appState.loadVMs()
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        let images = appState.imageLibrary.images
        List(selection: $selection) {
            Section("Virtual Machines") {
                ForEach(filteredVMs, id: \.self) { name in
                    VMRow(name: name)
                        .tag(SidebarSelection.vm(name))
                        // `swipeActions` on macOS 13+ surfaces the
                        // same trailing-swipe affordance iOS users
                        // expect. The `allowsFullSwipe: true` lets
                        // a full trailing swipe trigger delete
                        // without a secondary tap.
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                appState.deleteVM(name)
                                if selection == .vm(name) { selection = nil }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            Section("Images") {
                ForEach(images) { image in
                    Label(image.name, systemImage: "photo.stack")
                        .tag(SidebarSelection.image(image.id))
                        .contextMenu {
                            Button("Create VM from this image…") {
                                appState.showCreateSheet = true
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                try? appState.imageLibrary.remove(id: image.id)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                try? appState.imageLibrary.remove(id: image.id)
                                if selection == .image(image.id) { selection = nil }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                Button {
                    appState.showAddImage = true
                } label: {
                    Label("Add Image…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Workspaces")
        // Placing the search field explicitly in the sidebar
        // (`.sidebar`) renders it inside the sidebar's title
        // region instead of the toolbar. On macOS 26 this slot
        // auto-adopts the Liquid Glass styling Apple uses in
        // Finder's sidebar — rounded, translucent, tinted by
        // the window chrome — rather than the flat
        // `NSSearchToolbarItem` that `.automatic` placement
        // produces.
        .searchable(
            text: $searchText,
            placement: .sidebar,
            prompt: Text("Filter workspaces")
        )
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .vm(let name):
            if let bundle = appState.vms[name] {
                VMDetailView(name: name, bundle: bundle)
            } else {
                emptySelection
            }
        case .image(let id):
            if let image = appState.imageLibrary.images.first(where: { $0.id == id }) {
                ImageDetailView(image: image)
            } else {
                emptySelection
            }
        case .none:
            emptySelection
        }
    }

    @ViewBuilder
    private var emptySelection: some View {
        detailEmptyState
    }

    @ViewBuilder
    private var detailEmptyState: some View {
        if appState.vms.isEmpty {
            ContentUnavailableView {
                Label("No workspaces yet", systemImage: "sparkles")
            } description: {
                Text("Create your first macOS workspace to get started.")
            } actions: {
                Button("Create Workspace") {
                    appState.showCreateSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        } else {
            ContentUnavailableView(
                "Select a workspace",
                systemImage: "sidebar.left",
                description: Text("Choose one from the sidebar.")
            )
        }
    }

    // MARK: - Filtering

    private var filteredVMs: [String] {
        let all = appState.vms.keys.sorted()
        return searchText.isEmpty
            ? all
            : all.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
}
