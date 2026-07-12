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
            // The séance room: the ambient aurora sits behind every
            // detail state (hero, image detail, empty state) as a
            // bias over the system background — content renders on
            // top, never on glass.
            //
            // `backgroundExtensionEffect()` mirrors + blurs the
            // aurora into the safe areas around the detail column
            // (under the sidebar and title bar), which is Apple's
            // documented pattern for background content in a
            // `NavigationSplitView` detail column:
            // <https://developer.apple.com/documentation/SwiftUI/View/backgroundExtensionEffect()>
            // The aurora is near-uniform ambient light, so its
            // mirrored copies are seamless — the room reads
            // edge-to-edge without the content layer moving.
            ZStack {
                AuroraBackground()
                    .backgroundExtensionEffect()
                detail
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.showCreateSheet = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                        // Hover delight on the label (not the
                        // button) so only the symbol bounces;
                        // one-shot + Reduce-Motion-gated inside
                        // the modifier.
                        .hoverSymbolBounce()
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
            if let message = appState.errorMessage {
                if let suggestion = appState.errorSuggestedAction {
                    Text("\(message)\n\n\(suggestion)")
                } else {
                    Text(message)
                }
            }
        }
        .alert("Done", isPresented: $state.infoPresented) {
            Button("OK", role: .cancel) {
                appState.infoMessage = nil
            }
        } message: {
            if let message = appState.infoMessage { Text(message) }
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
            Section {
                // Pending creations render above the live VM list
                // so the user sees the row they just asked for
                // immediately (not buried below alphabetical
                // neighbors). Rows are deliberately un-tagged so
                // clicking them doesn't drive the detail pane to
                // an empty-state for a not-yet-loaded bundle.
                ForEach(pendingCreations, id: \.id) { pending in
                    PendingVMRow(pending: pending)
                }

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
            } header: {
                // Counts reflect the rows actually beneath the
                // header (search-filtered), so the number never
                // contradicts what the user sees. The running
                // summary is global state — it stays truthful
                // even when a running VM is filtered out.
                SidebarSectionHeader(
                    title: "Virtual Machines",
                    count: filteredVMs.count + pendingCreations.count,
                    runningCount: appState.runningVMs.count
                )
            }
            Section {
                ForEach(images) { image in
                    ImageRow(image: image)
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
                        // Same hover-bounce contract as the
                        // toolbar action — the row is interactive,
                        // so its symbol responds to the pointer.
                        .hoverSymbolBounce()
                }
                .buttonStyle(.plain)
            } header: {
                SidebarSectionHeader(title: "Images", count: images.count)
            }
        }
        .listStyle(.sidebar)
        // Scoped accent for the selection highlight only — without
        // it the sidebar selects in the system accent (blue on most
        // Macs), which reads off-brand against the wisp identity.
        // Deliberately NOT applied at the window root: a root tint
        // cascades into every glass button fill (the candy-bar bug).
        .tint(Apparition.wisp)
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
            // First-run séance: `EmptyStateView` sits directly over
            // the aurora (no material between them) and carries this
            // surface's single `glassProminent` wisp action.
            EmptyStateView {
                appState.showCreateSheet = true
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

    /// `vms` dictionary keys (bundle UUID strings), sorted and
    /// filtered by each bundle's ``VirtualMachineBundle/displayName``
    /// — never by the raw key — so the sidebar order and search
    /// match what the user actually sees in each `VMRow`.
    private var filteredVMs: [String] {
        func displayName(_ key: String) -> String {
            appState.vms[key]?.displayName ?? key
        }
        let all = appState.vms.keys.sorted {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }
        return searchText.isEmpty
            ? all
            : all.filter { displayName($0).localizedCaseInsensitiveContains(searchText) }
    }

    /// Live list of in-flight creations for the sidebar, filtered
    /// by the same search query as ``filteredVMs``. Sorted by name
    /// for a stable visual order — `Dictionary.values` makes no
    /// ordering guarantee, so without the sort SwiftUI's diffing
    /// can't tell "progress moved" from "row reordered."
    private var pendingCreations: [AppState.PendingCreation] {
        let all = appState.pendingCreations.values.sorted { $0.name < $1.name }
        return searchText.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
}

// MARK: - Section Header

/// Sidebar section header with a live trailing count — and, when
/// any workspace is alive, a vital-colored "N running" summary so
/// fleet health reads from the header without scanning rows.
///
/// Both numbers roll with `.contentTransition(.numericText())`
/// scoped by `.animation(_:value:)` to exactly those two values;
/// under Reduce Motion the animation is `nil`, so counts snap.
/// Digits are monospaced so the header doesn't shimmy as counts
/// change width.
private struct SidebarSectionHeader: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let count: Int
    var runningCount: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 4)
            if runningCount > 0 {
                Text("\(runningCount) running")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Apparition.vital)
                    .contentTransition(.numericText())
            }
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
        .animation(reduceMotion ? nil : Apparition.quick, value: count)
        .animation(reduceMotion ? nil : Apparition.quick, value: runningCount)
        // Section headers get less trailing inset than list rows on
        // macOS sidebars, so without this the counts hug the window
        // edge instead of respecting the same margin as the filter
        // field and row content.
        .padding(.trailing, 12)
    }
}

// MARK: - Image Row

/// Sidebar row for one library image — kind medallion, name, and
/// a size + added-date caption, mirroring ``VMRow``'s
/// medallion-title-caption anatomy so the two sections read as
/// one system.
///
/// The medallion is the kind cue: local restore media (`.ipsw`)
/// gets **cyan**, OCI references get **brown**. Chosen against
/// the Apparition palette on night grounds: cyan is blue-leaning
/// where ``Apparition/vital`` teal is green-leaning (and no image
/// row ever carries a vital state dot to collide with); brown is
/// a muted tan where ``Apparition/lantern`` amber is bright and
/// saturated — and both sit far from the wisp violet. Local
/// `.iso` files ride the `.ipsw` case in the model, so the glyph
/// borrows the detail hero's extension sniff (disc, not Apple
/// logo) while keeping the local-file color.
private struct ImageRow: View {

    let image: VirtualMachineImage

    private var isOCI: Bool {
        if case .oci = image.source { return true }
        return false
    }

    private var glyph: String {
        switch image.source {
        case .ipsw(let path):
            path.lowercased().hasSuffix(".iso") ? "opticaldisc.fill" : "apple.logo"
        case .oci:
            "shippingbox.fill"
        }
    }

    private var kindColor: Color { isOCI ? .brown : .cyan }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kindColor)
                .frame(width: 24, height: 24)
                .background(kindColor.opacity(0.16), in: .circle)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(image.name)
                    .font(.body)
                    .lineLimit(1)
                Text(caption)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// "12.4 GB · added 2 weeks ago" — `.file` byte counting to
    /// match Finder, named relative date so recency reads without
    /// arithmetic. Size-less entries (some OCI references) drop
    /// straight to the date.
    private var caption: String {
        let added = image.addedAt.formatted(.relative(presentation: .named))
        if let bytes = image.sizeInBytes {
            let size = Int64(clamping: bytes).formatted(.byteCount(style: .file))
            return "\(size) · added \(added)"
        }
        return "Added \(added)"
    }
}
