import SwiftUI
import SFSymbolsKit
import UniformTypeIdentifiers
import SpooktacularInfrastructureApple

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

    /// Presentation flag for the File → Import VM Bundle…
    /// file picker. Lives on the `App` rather than the
    /// `ContentView` so the keyboard shortcut (⇧⌘O) works
    /// even when the library window isn't focused.
    @State private var showImporter: Bool = false

    private var menuBarSymbol: String {
        if appState.isAnyVMTransitioning { return String.SFSymbols.hourglassCircle }
        return appState.runningVMs.isEmpty
            ? String.SFSymbols.squareStack3dUp
            : String.SFSymbols.squareStack3dUpFill
    }

    /// Opens a web URL in the user's default browser. No-op on a
    /// malformed string — avoids force-unwrapping `URL(string:)`.
    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
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
                // Handles double-clicked `.vm` bundles and the
                // `Open With → Spooktacular` Finder action.
                // The CFBundleDocumentTypes + UTExportedTypeDeclarations
                // entries in Info.plist register us as the
                // "Owner" handler for
                // `com.spookylabs.spooktacular.vm-bundle`; Apple
                // dispatches the URL here via SwiftUI's
                // `onOpenURL(perform:)`.
                //
                // Docs:
                //   https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)
                .onOpenURL { url in
                    Task { await appState.importBundle(from: url) }
                }
                // File → Import VM Bundle… uses Apple's
                // `.fileImporter` with the typed
                // `UTType.spooktacularVMBundle` filter so the
                // picker only surfaces owned bundles and
                // folders — never stray disk images, IPSWs, or
                // plaintext files. Multi-select is on so users
                // can drag three bundles off a USB drive at
                // once. Docs:
                // https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:)
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.spooktacularVMBundle],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        Task {
                            for url in urls {
                                await appState.importBundle(from: url)
                            }
                        }
                    case .failure(let error):
                        appState.presentError(error)
                    }
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

                Divider()

                // Import VM Bundle… opens `.fileImporter`
                // filtered by `UTType.spooktacularVMBundle` so
                // Finder only lets the user pick our owned
                // UTI. The system's double-click route still
                // flows through `.onOpenURL` above — this
                // command is for users who prefer the File
                // menu or need multi-select import from a USB
                // stick.
                Button("Import VM Bundle…") {
                    showImporter = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Standard SwiftUI sidebar-toggle command group —
            // surfaces View → Show Sidebar / Hide Sidebar with
            // the platform-standard ⌃⌘S shortcut.
            //
            // Docs: https://developer.apple.com/documentation/swiftui/sidebarcommands
            SidebarCommands()

            CommandGroup(replacing: .help) {
                Button("Spooktacular Help") {
                    Self.open("https://spooktacular.app/")
                }
                .keyboardShortcut("?", modifiers: .command)
                Divider()
                // The published SpooktacularKit DocC — the actual API/CLI
                // reference, not the marketing feature page.
                Button("CLI & API Reference") {
                    Self.open("https://spooktacular.app/api/documentation/spooktacularkit/")
                }
                Button("Security & Compliance") {
                    Self.open("https://spooktacular.app/security.html")
                }
                Divider()
                Button("Report an Issue…") {
                    Self.open("https://github.com/Spooky-Labs/spooktacular/issues")
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
