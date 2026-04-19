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
                // Opaque glass-material background on the library
                // window. Without this, the window content area is
                // fully transparent — the desktop wallpaper bleeds
                // through (observed: user report "main app's
                // background is clear and that's weird").
                //
                // `.libraryWindowBackground()` picks the best
                // API for the running OS: `containerBackground`
                // (macOS 15+) → `background` (macOS 14). See the
                // extension below for the `#available` selector
                // and Apple doc citations.
                .libraryWindowBackground()
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

        // MARK: - Help Window
        //
        // First-class SwiftUI help window — searchable, topic-driven,
        // opens via `openWindow(id: "help")` or
        // `openWindow(id: "help", value: slug)` when a specific
        // topic should be pre-selected. Keeps the legacy
        // `Help.bundle` / AHT format out of the codebase —
        // SwiftUI handles search, layout, and Markdown rendering
        // natively.
        //
        // Docs:
        // - WindowGroup(id:for:):
        //   https://developer.apple.com/documentation/swiftui/windowgroup
        // - openWindow:
        //   https://developer.apple.com/documentation/swiftui/environmentvalues/openwindow
        WindowGroup(id: "help", for: String?.self) { $initialSlug in
            HelpView(initialSlug: initialSlug)
        } defaultValue: {
            nil
        }
        .defaultSize(width: 880, height: 620)
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
        // Apple's macOS HIG reserves `CommandGroup(replacing: .help)`
        // for the app-specific Help menu items — keyboard shortcut
        // ⌘? on the first item is the platform convention.
        //
        // Docs (menus): https://developer.apple.com/design/human-interface-guidelines/menus
        // Docs (CommandGroup): https://developer.apple.com/documentation/swiftui/commandgroup
        CommandGroup(replacing: .help) {
            HelpMenuItems()
        }
    }
}

// MARK: - Help menu items

/// The Help menu's content, extracted into a View so each item can
/// reach the `openWindow` environment value — `CommandGroup` does
/// not directly bind `@Environment` on its own closure, so the
/// indirection through a View gives each button a valid scene
/// environment.
///
/// Docs: https://developer.apple.com/documentation/swiftui/environmentvalues/openwindow
private struct HelpMenuItems: View {

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Spooktacular Help") {
            openWindow(id: "help", value: Optional<String>.none)
        }
        // ⌘? — standard macOS shortcut for the primary Help item.
        .keyboardShortcut("?", modifiers: [.command])

        Divider()

        Button("Getting Started") {
            openWindow(id: "help", value: Optional("welcome"))
        }

        Button("Creating a Virtual Machine") {
            openWindow(id: "help", value: Optional("creating-a-vm"))
        }

        Button("Keyboard Shortcuts") {
            openWindow(id: "help", value: Optional("keyboard-shortcuts"))
        }

        Divider()

        Button("GitHub Actions Runner Setup") {
            openWindow(id: "help", value: Optional("github-runner"))
        }

        Button("Remote Desktop Guide") {
            openWindow(id: "help", value: Optional("remote-desktop-intro"))
        }

        Button("CLI Reference") {
            openWindow(id: "help", value: Optional("cli-basics"))
        }

        Divider()

        // External links stay out of the in-app help window — the
        // DocC archive and the GitHub issue tracker are richer in
        // a browser than in a SwiftUI pane. `NSWorkspace.open(_:)`
        // honours the user's default handler for each URL scheme.
        //
        // Docs: https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)
        Button("API Documentation (DocC)") {
            if let url = URL(string: "https://spooktacular.app/api/documentation/spooktacularkit/") {
                NSWorkspace.shared.open(url)
            }
        }

        Button("Report an Issue…") {
            if let url = URL(string: "https://github.com/Spooky-Labs/spooktacular/issues") {
                NSWorkspace.shared.open(url)
            }
        }

        Button("Release Notes") {
            if let url = URL(string: "https://github.com/Spooky-Labs/spooktacular/releases") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Library window background

private extension View {

    /// Applies the Liquid Glass window background to the library
    /// window, picking the best Apple API for the running OS.
    ///
    /// - **macOS 15+**:
    ///   `containerBackground(.ultraThinMaterial, for: .window)`
    ///   — purpose-built for window-wide material fills,
    ///   resilient to split-view reshuffling. This is the
    ///   recommended API in Apple's
    ///   ["Giving a window a custom background"](https://developer.apple.com/documentation/swiftui/view/containerbackground(_:for:))
    ///   sample.
    /// - **macOS 14**: `background(.ultraThinMaterial)` —
    ///   visually identical under the library's single
    ///   `NavigationSplitView`, and the documented
    ///   ["Material"](https://developer.apple.com/documentation/swiftui/material)
    ///   pattern for general material fills on SwiftUI views.
    ///
    /// Using an `#available` guard (rather than a shared
    /// deployment-target bump) keeps macOS 14 users' install
    /// count valid through Spooktacular's pre-1.0 phase; both
    /// paths produce the same pixel effect, so there's no
    /// feature-parity risk.
    func libraryWindowBackground() -> some View {
        Group {
            if #available(macOS 15.0, *) {
                self.containerBackground(.ultraThinMaterial, for: .window)
            } else {
                self.background(.ultraThinMaterial)
            }
        }
    }
}
