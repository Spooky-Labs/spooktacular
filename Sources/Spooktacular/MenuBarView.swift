import SwiftUI
import SpooktacularKit

/// The menu bar dropdown for quick VM management.
///
/// Shows all VMs with their status, provides start/stop actions,
/// and links to the main window. Uses SF Symbols throughout
/// for a native macOS feel.
struct MenuBarView: View {

    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.vms.isEmpty {
            Label("No Virtual Machines", systemImage: "square.stack.3d.up.slash")
                .foregroundStyle(.secondary)
            Divider()
        } else {
            ForEach(sortedNames, id: \.self) { name in
                vmMenuItem(name: name)
            }

            Divider()

            let running = appState.runningVMs.count
            let total = appState.vms.count
            Label(
                "\(running) of \(total) running",
                systemImage: "gauge.with.dots.needle.33percent"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
        }

        Button {
            appState.showCreateSheet = true
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            Label("New Virtual Machine…", systemImage: "plus.square.on.square")
        }
        .keyboardShortcut("n", modifiers: [.command])

        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Spooktacular", systemImage: "macwindow")
        }
        .keyboardShortcut("o", modifiers: [.command])

        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
        } label: {
            Label("Settings…", systemImage: "gear")
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Spooktacular", systemImage: "power")
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    // MARK: - VM Menu Item

    @ViewBuilder
    private func vmMenuItem(name: String) -> some View {
        let isRunning = appState.isRunning(name)

        if isRunning {
            Menu {
                Button("Stop", systemImage: "stop.fill") {
                    Task { await appState.stopVM(name) }
                }
                Divider()
                Button("Show in Window", systemImage: "macwindow") {
                    appState.selectedVM = name
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } label: {
                Label {
                    Text(name) + Text("  ") + Text("Running").foregroundColor(.green)
                } icon: {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        } else {
            Menu {
                Button("Start", systemImage: "play.fill") {
                    Task { await appState.startVM(name) }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Divider()
                Button("Show in Window", systemImage: "macwindow") {
                    appState.selectedVM = name
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } label: {
                Label(name, systemImage: "stop.circle")
            }
        }
    }

    private var sortedNames: [String] {
        appState.vms.keys.sorted()
    }
}
