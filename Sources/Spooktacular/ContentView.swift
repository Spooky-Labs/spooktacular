import SwiftUI
import SpooktacularKit

/// Library window — pure `NavigationSplitView`. Sidebar on the
/// left, detail on the right. No custom chrome, no overrides.
struct ContentView: View {

    @Environment(AppState.self) private var appState

    @State private var selection: String?
    @State private var searchText = ""
    @State private var didLoad = false

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
                    VMRow(name: name).tag(name)
                }
            }
            Section("Images") {
                ForEach(images) { image in
                    Label(image.name, systemImage: "photo.stack")
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
        .searchable(text: $searchText, prompt: "Filter")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let name = selection, let bundle = appState.vms[name] {
            VMDetailView(name: name, bundle: bundle)
        } else if appState.vms.isEmpty {
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
