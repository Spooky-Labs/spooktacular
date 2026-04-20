import SwiftUI
import SpooktacularKit

/// Snapshot management UI surfaced as a glass sheet on the
/// workspace window.
///
/// Delegates all persistence to ``SnapshotManager`` — no new
/// logic lives here, it's purely a SwiftUI shell over the same
/// save / restore / list / delete operations the CLI exposes.
/// Loads the snapshot list on appear and after every mutating
/// action so the UI stays in sync with disk.
///
/// The VM must be stopped for save / restore; the UI disables
/// those rows when the workspace is running and shows a helpful
/// inline hint.
struct SnapshotInspector: View {

    let vmName: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [SnapshotInfo] = []
    @State private var newLabel: String = ""
    @State private var errorMessage: String?
    @State private var isBusy: Bool = false

    private var bundle: VirtualMachineBundle? {
        appState.vms[vmName]
    }

    private var isRunning: Bool {
        appState.isRunning(vmName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 420, idealWidth: 480, minHeight: 360, idealHeight: 440)
        .task(id: vmName) { reload() }
        .alert(
            "Snapshot error",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            if let message = errorMessage {
                Text(message)
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label("Snapshots", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if snapshots.isEmpty {
            ContentUnavailableView(
                "No Snapshots",
                systemImage: "camera.aperture",
                description: Text("Save a snapshot before making risky changes.")
            )
            .padding(32)
            .frame(maxHeight: .infinity)
        } else {
            List {
                ForEach(snapshots, id: \.label) { info in
                    SnapshotRow(
                        info: info,
                        running: isRunning,
                        onRestore: { restore(label: info.label) },
                        onDelete: { delete(label: info.label) }
                    )
                }
            }
            .listStyle(.inset)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            TextField("Snapshot label", text: $newLabel)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning || isBusy)

            Button {
                save(label: newLabel)
            } label: {
                Label("Save", systemImage: "camera.fill")
            }
            .glassButton()
            .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty
                      || isRunning
                      || isBusy)
            .help(isRunning
                  ? "Stop the workspace to take a snapshot"
                  : "Save the current disk state under this label")
        }
        .padding(16)
    }

    // MARK: - Actions

    private func reload() {
        guard let bundle else { return }
        do {
            snapshots = try SnapshotManager.list(bundle: bundle)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(label: String) {
        guard let bundle, !isBusy else { return }
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        isBusy = true
        defer { isBusy = false }
        do {
            try SnapshotManager.save(bundle: bundle, label: trimmed)
            newLabel = ""
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func restore(label: String) {
        guard let bundle, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try SnapshotManager.restore(bundle: bundle, label: label)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete(label: String) {
        guard let bundle, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try SnapshotManager.delete(bundle: bundle, label: label)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Row

/// Single-snapshot row in ``SnapshotInspector``.
struct SnapshotRow: View {
    let info: SnapshotInfo
    let running: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.label)
                    .font(.body.weight(.medium))
                HStack(spacing: 8) {
                    Text(
                        info.createdAt,
                        format: .dateTime.month().day().year().hour().minute()
                    )
                    Text("·")
                    Text(humanBytes(info.sizeInBytes))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Borderless stays correct for row-embedded actions
            // — Apple's HIG calls out that densely packed list
            // rows should avoid per-row glass pills (they turn
            // into stacked panes and cost render time). Glass
            // lives on the header/footer CTAs where one prominent
            // action reads clearly.
            Button("Restore", systemImage: "arrow.uturn.backward", action: onRestore)
                .buttonStyle(.borderless)
                .disabled(running)
                .help(running
                      ? "Stop the workspace to restore this snapshot"
                      : "Restore the workspace to this snapshot")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this snapshot")
        }
        .padding(.vertical, 4)
    }

    /// Inline duplicate of the CLI's humanizeBytes so the library
    /// target has no dependency on the `spook` executable target.
    /// Kept private-to-file to avoid namespace pollution.
    private func humanBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value < 1024 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var size = value / 1024
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return String(format: "%.1f %@", size, units[unit])
    }
}
