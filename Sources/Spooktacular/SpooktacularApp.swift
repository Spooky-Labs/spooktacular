import SwiftUI

/// The Spooktacular macOS application.
///
/// Uses a multi-window scene architecture:
///
/// - **Library window** (`id: "library"`) — the home view: VM list,
///   search, create/clone/delete. Always presented at launch.
/// - **Workspace window** (`id: "workspace", for: String.self`) —
///   one window per running VM, opened by passing the VM name to
///   `openWindow(id:value:)`. Hosts `VZVirtualMachineView` and a
///   Liquid-Glass toolbar.
///
/// This matches the GhostVM pattern where each VM feels like its
/// own app: the library is just the dashboard; workspaces stand
/// on their own and can remain open after the library is hidden.
///
/// ## Window Restoration
///
/// Open workspace windows are persisted to
/// `@AppStorage("openWorkspaces")` as a JSON array of names. On
/// the next launch ``ContentView`` iterates the stored list and
/// calls `openWindow(id:value:)` for each. VMs that no longer
/// exist are silently skipped.
@main
struct SpooktacularApp: App {

    @State private var appState = AppState()

    /// Controls whether the menu-bar icon renders as a busy
    /// indicator when any VM is mid-transition (starting, stopping,
    /// or cloning).
    private var menuBarSymbol: String {
        if appState.isAnyVMTransitioning { return "hourglass.circle" }
        return appState.runningVMs.isEmpty
            ? "square.stack.3d.up"
            : "square.stack.3d.up.fill"
    }

    var body: some Scene {

        // MARK: - Library Window

        WindowGroup(id: "library") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 720, minHeight: 460)
                // Window background is left to the system. On
                // macOS 26 the `NavigationSplitView` + sidebar
                // + toolbar combination automatically renders
                // with Liquid Glass chrome; on earlier macOS
                // the default window background / vibrancy
                // applies. Any custom `containerBackground` or
                // `background(.ultraThinMaterial)` here fights
                // the standard split-view chrome and — combined
                // with toolbar-background overrides — produces
                // a transparent window with a floating sidebar
                // (observed regression on macOS 26).
                // Principle from Apple's adoption guide: "use
                // standard app structures, toolbars, search
                // placements, and controls" and let the system
                // do the glass.
                .sheet(isPresented: Bindable(appState).showAddImage) {
                    AddImageSheet()
                        .environment(appState)
                }
                .sheet(isPresented: Bindable(appState).showCommandPalette) {
                    CommandPalette()
                        .environment(appState)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.stopAllRunningVMs()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 960, height: 640)
        .commands {
            workspaceCommands
            helpCommands
        }

        // MARK: - Workspace Windows

        WindowGroup(id: "workspace", for: String.self) { $vmName in
            if let name = vmName {
                WorkspaceWindow(vmName: name)
                    .environment(appState)
            }
        }
        .defaultSize(width: 1024, height: 640)
        .windowResizability(.contentMinSize)

        // MARK: - Settings

        Settings {
            SettingsView()
                .environment(appState)
        }

        // MARK: - Menu Bar

        MenuBarExtra(
            "Spooktacular",
            systemImage: menuBarSymbol
        ) {
            MenuBarView()
                .environment(appState)
        }
    }

    // MARK: - Command Groups

    @CommandsBuilder
    private var workspaceCommands: some Commands {
        // `replacing: .newItem` (not `after:`) so SwiftUI
        // *removes* the default "New Window" Cmd+N entry that a
        // `WindowGroup` otherwise synthesises. Without this,
        // Cmd+N triggers both our "New Virtual Machine…" and
        // the default new-window handler — the visible bug was
        // a second, narrow, empty library window spawning
        // beside the main one.
        //
        // Docs: https://developer.apple.com/documentation/swiftui/commandgroupplacement/newitem
        CommandGroup(replacing: .newItem) {
            Button("New Virtual Machine…") {
                appState.showCreateSheet = true
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Add Image…") {
                appState.showAddImage = true
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])

            Button("Open Command Palette") {
                appState.showCommandPalette = true
            }
            .keyboardShortcut("k", modifiers: [.command])
        }
    }

    @CommandsBuilder
    private var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            Button("Spooktacular Help") {
                NSWorkspace.shared.open(URL(string: "https://spooktacular.dev/docs")!)
            }

            Divider()

            Button("Getting Started") {
                NSWorkspace.shared.open(URL(string: "https://spooktacular.dev/docs/getting-started")!)
            }

            Button("CLI Reference") {
                NSWorkspace.shared.open(URL(string: "https://spooktacular.dev/docs/cli")!)
            }

            Button("Kubernetes Guide") {
                NSWorkspace.shared.open(URL(string: "https://spooktacular.dev/docs/kubernetes")!)
            }

            Divider()

            Button("Report an Issue…") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Spooky-Labs/spooktacular/issues")!)
            }

            Button("Release Notes") {
                NSWorkspace.shared.open(URL(string: "https://github.com/Spooky-Labs/spooktacular/releases")!)
            }
        }
    }
}

// No custom window-background helper. The library window uses
// the system default on every macOS version — Liquid Glass on
// 26+, vibrancy + material on 14–15 — because custom container
// backgrounds fight the standard `NavigationSplitView` chrome
// and produce a transparent window with a floating sidebar on
// macOS 26. Principle from Apple's adoption guide: "use
// standard app structures, toolbars, search placements, and
// controls" and let the system apply the glass.
