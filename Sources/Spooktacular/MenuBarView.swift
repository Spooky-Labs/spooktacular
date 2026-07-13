import SwiftUI
import SFSymbolsKit
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
            Label("No Virtual Machines", systemImage: String.SFSymbols.squareStack3dUpSlash)
                .foregroundStyle(.secondary)
            Divider()
        } else {
            ForEach(sortedNames, id: \.self) { name in
                vmMenuItem(name: name)
            }

            Divider()

            let running = appState.runningVMs.count
            let total = appState.vms.count
            let isBooting = !appState.transitioningVMs.isEmpty
            Label(
                "\(running) of \(total) running",
                systemImage: String.SFSymbols.gaugeWithDotsNeedle33percent
            )
            .font(.caption)
            // Machine-speak counts get tabular digits so the line
            // doesn't jitter as running/total change.
            .monospacedDigit()
            .foregroundStyle(.secondary)
            // The gauge glyph reflects live running-VM state, the
            // one thing persona A scans this summary line for:
            // pulse while any VM is mid start/stop (`transitioningVMs`
            // is non-empty), and bounce the instant the running count
            // changes — a VM just came online (or went offline).
            .symbolEffect(.pulse, isActive: isBooting)
            .symbolEffect(.bounce, value: running)

            Divider()
        }

        Button {
            appState.showCreateSheet = true
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            Label("New Virtual Machine…", systemImage: String.SFSymbols.plusSquareOnSquare)
        }
        .keyboardShortcut("n", modifiers: [.command])

        Button {
            NSApplication.shared.activate(ignoringOtherApps: true)
        } label: {
            Label("Open Spooktacular", systemImage: String.SFSymbols.macwindow)
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
            Label("Settings…", systemImage: String.SFSymbols.gear)
        }
        .keyboardShortcut(",", modifiers: [.command])

        Divider()

        Button {
            NSApplication.shared.terminate(nil)
        } label: {
            Label("Quit Spooktacular", systemImage: String.SFSymbols.power)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    // MARK: - VM Menu Item

    @ViewBuilder
    private func vmMenuItem(name: String) -> some View {
        let displayName = appState.vms[name]?.displayName ?? name
        let isRunning = appState.isRunning(name)
        let isTransitioning = appState.transitioningVMs.contains(name)

        if isTransitioning {
            // Show an hourglass while the VM is mid-start/stop —
            // gives immediate feedback that the click registered.
            Label {
                HStack(spacing: 4) {
                    Text(displayName)
                    Text("…").foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: String.SFSymbols.hourglass)
                    // Lantern = materializing / in-progress in the
                    // Apparition palette.
                    .foregroundStyle(Apparition.lantern)
            }
        } else if isRunning {
            Menu {
                Button("Stop", systemImage: String.SFSymbols.stopFill) {
                    Task { await appState.stopVM(name) }
                }
                Divider()
                Button("Show in Window", systemImage: String.SFSymbols.macwindow) {
                    appState.selectedVM = name
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } label: {
                Label {
                    HStack(spacing: 4) {
                        Text(displayName)
                        // Vital = alive / online in the Apparition
                        // palette — never the wisp accent.
                        Text("Running").foregroundStyle(Apparition.vital)
                    }
                } icon: {
                    Image(systemName: String.SFSymbols.playCircleFill)
                        .foregroundStyle(Apparition.vital)
                }
            }
        } else {
            Menu {
                Button("Start", systemImage: String.SFSymbols.playFill) {
                    Task { await appState.startVM(name) }
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                Divider()
                Button("Show in Window", systemImage: String.SFSymbols.macwindow) {
                    appState.selectedVM = name
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
            } label: {
                Label(displayName, systemImage: String.SFSymbols.stopCircle)
            }
        }
    }

    /// `vms` keys sorted by each bundle's display name — never by
    /// the raw UUID key.
    private var sortedNames: [String] {
        appState.vms.keys.sorted {
            (appState.vms[$0]?.displayName ?? $0)
                .localizedCaseInsensitiveCompare(appState.vms[$1]?.displayName ?? $1) == .orderedAscending
        }
    }
}
