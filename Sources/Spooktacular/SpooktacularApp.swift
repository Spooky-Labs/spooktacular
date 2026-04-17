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
        CommandGroup(after: .newItem) {
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
