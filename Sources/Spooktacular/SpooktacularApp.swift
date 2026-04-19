import SwiftUI

/// Spooktacular — macOS virtualization for the datacenter.
///
/// Kept intentionally minimal: scene declarations only, zero
/// custom window chrome, zero custom container backgrounds. On
/// macOS 26 the standard `NavigationSplitView` + toolbar combo
/// renders Liquid Glass chrome automatically; on macOS 14–15 we
/// get the default vibrancy + material treatment. Fighting the
/// system here caused the transparent-window + detached-sidebar
/// regressions we spent a day chasing — don't reintroduce.
///
/// Docs:
/// - Designing for macOS:
///   https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
/// - Adopting Liquid Glass:
///   https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
@main
struct SpooktacularApp: App {

    @State private var appState = AppState()

    private var menuBarSymbol: String {
        if appState.isAnyVMTransitioning { return "hourglass.circle" }
        return appState.runningVMs.isEmpty
            ? "square.stack.3d.up"
            : "square.stack.3d.up.fill"
    }

    var body: some Scene {

        // ────────────── Library window ──────────────
        WindowGroup(id: "library") {
            ContentView()
                .environment(appState)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    appState.stopAllRunningVMs()
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            // Replace the default "New Window" command group so
            // Cmd+N doesn't spawn a duplicate library window.
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
            }

            // Standard SwiftUI sidebar-toggle command group —
            // surfaces View → Show Sidebar / Hide Sidebar with
            // the platform-standard ⌃⌘S shortcut.
            //
            // Docs: https://developer.apple.com/documentation/swiftui/sidebarcommands
            SidebarCommands()

            CommandGroup(replacing: .help) {
                Button("Spooktacular Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.app/")!
                    )
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                Button("CLI Reference") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.app/features.html")!
                    )
                }
                Button("Security & Compliance") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.app/security.html")!
                    )
                }
                Divider()
                Button("Report an Issue…") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/Spooky-Labs/spooktacular/issues")!
                    )
                }
            }
        }

        // ────────────── Workspace windows ──────────────
        // One window per running VM. Identified by VM name so
        // `openWindow(id: "workspace", value: name)` brings the
        // existing window forward instead of spawning a duplicate.
        WindowGroup(id: "workspace", for: String.self) { $vmName in
            if let name = vmName {
                WorkspaceWindow(vmName: name)
                    .environment(appState)
            }
        }
        .defaultSize(width: 1024, height: 640)

        // ────────────── Settings ──────────────
        Settings {
            SettingsView()
                .environment(appState)
        }

        // ────────────── Menu bar ──────────────
        MenuBarExtra(
            "Spooktacular",
            systemImage: menuBarSymbol
        ) {
            MenuBarView()
                .environment(appState)
        }
    }
}
