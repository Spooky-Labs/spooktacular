import SwiftUI

/// The Spooktacular macOS application.
@main
struct SpooktacularApp: App {

    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 600, minHeight: 400)
                .sheet(isPresented: Bindable(appState).showAddImage) {
                    AddImageSheet()
                        .environment(appState)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    appState.stopAllRunningVMs()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Virtual Machine…") {
                    appState.showCreateSheet = true
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Add Image…") {
                    appState.showAddImage = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                Button("Spooktacular Help") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.dev/docs")!
                    )
                }

                Divider()

                Button("Getting Started") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.dev/docs/getting-started")!
                    )
                }

                Button("CLI Reference") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.dev/docs/cli")!
                    )
                }

                Button("Kubernetes Guide") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.dev/docs/kubernetes")!
                    )
                }

                Button("Provisioning Modes") {
                    NSWorkspace.shared.open(
                        URL(string: "https://spooktacular.dev/docs/provisioning")!
                    )
                }

                Divider()

                Button("Report an Issue…") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/spooktacular/spooktacular/issues")!
                    )
                }

                Button("Release Notes") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/spooktacular/spooktacular/releases")!
                    )
                }
            }
        }

        Settings {
            SettingsView()
        }

        MenuBarExtra(
            "Spooktacular",
            systemImage: appState.runningVMs.isEmpty
                ? "square.stack.3d.up"
                : "square.stack.3d.up.fill"
        ) {
            MenuBarView()
                .environment(appState)
        }
    }
}
