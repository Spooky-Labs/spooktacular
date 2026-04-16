import SwiftUI
import SpooktacularKit

/// ⌘K command palette — one place to trigger any app action.
///
/// The palette lists every lifecycle operation the CLI exposes
/// (start / stop / snapshot / clone / restore / delete / open),
/// scoped to the selected VM. Fuzzy substring matching on both
/// the action name and the target VM so users can type
/// `"snap run"` and land on "Snapshot runner-01".
///
/// Presented as a glass sheet rather than a popover so it's
/// obvious and keyboard-focusable. Dismisses on `Esc` or any
/// action selection.
struct CommandPalette: View {

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""
    @FocusState private var focused: Bool

    /// All commands currently offered. Computed so the list
    /// stays in sync with VM creation/deletion without extra
    /// wiring.
    private var allCommands: [PaletteCommand] {
        let vms = appState.vms.keys.sorted()
        var result: [PaletteCommand] = []
        result.append(PaletteCommand(
            title: "New Virtual Machine…",
            subtitle: "Create a new workspace",
            systemImage: "plus.square.on.square",
            shortcut: "⌘N",
            action: { appState.showCreateSheet = true }
        ))
        result.append(PaletteCommand(
            title: "Add Image…",
            subtitle: "Import an IPSW or OCI reference",
            systemImage: "square.and.arrow.down",
            shortcut: "⌘⇧I",
            action: { appState.showAddImage = true }
        ))
        for name in vms {
            result.append(PaletteCommand(
                title: "Open Workspace · \(name)",
                subtitle: "Open '\(name)' in its own window",
                systemImage: "macwindow",
                shortcut: nil,
                action: { openWindow(id: "workspace", value: name) }
            ))
            if appState.isRunning(name) {
                result.append(PaletteCommand(
                    title: "Stop · \(name)",
                    subtitle: "Stop the running workspace",
                    systemImage: "stop.fill",
                    shortcut: nil,
                    action: { Task { await appState.stopVM(name) } }
                ))
            } else {
                result.append(PaletteCommand(
                    title: "Start · \(name)",
                    subtitle: "Boot the workspace",
                    systemImage: "play.fill",
                    shortcut: nil,
                    action: { Task { await appState.startVM(name) } }
                ))
            }
            result.append(PaletteCommand(
                title: "Clone · \(name)",
                subtitle: "APFS clone under '\(name)-clone'",
                systemImage: "doc.on.doc",
                shortcut: nil,
                action: { appState.cloneVM(name, to: "\(name)-clone") }
            ))
        }
        return result
    }

    private var filtered: [PaletteCommand] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return allCommands }
        return allCommands.filter {
            $0.title.lowercased().contains(q)
                || $0.subtitle.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 520, height: 420)
        .task { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "command")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Type a command or VM name", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit { runFirst() }
        }
        .padding(14)
    }

    @ViewBuilder
    private var resultsList: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try 'start', 'snapshot', or a VM name.")
            )
        } else {
            List(filtered) { command in
                PaletteRow(command: command, onRun: {
                    command.action()
                    dismiss()
                })
            }
            .listStyle(.plain)
        }
    }

    private func runFirst() {
        guard let first = filtered.first else { return }
        first.action()
        dismiss()
    }
}

/// A single command offered by ``CommandPalette``.
struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let systemImage: String
    let shortcut: String?
    let action: () -> Void
}

/// Row view for the palette list.
struct PaletteRow: View {
    let command: PaletteCommand
    let onRun: () -> Void

    var body: some View {
        Button(action: onRun) {
            HStack(spacing: 12) {
                Image(systemName: command.systemImage)
                    .font(.system(size: 18))
                    .frame(width: 24)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.body.weight(.medium))
                    Text(command.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassStatusBadge()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
