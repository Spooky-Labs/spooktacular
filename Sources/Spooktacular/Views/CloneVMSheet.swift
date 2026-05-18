import SwiftUI
import SpooktacularKit

/// Modal sheet for cloning a virtual machine.
///
/// Mirrors the CLI's `spook clone <source> <destination>` — the
/// sidebar's context-menu "Clone…" item presents this sheet so
/// operators can pick a destination name instead of silently
/// falling into an auto-suffixed `<source>-clone`. Runner-pool
/// workflows (`runner-01`, `runner-02`, …) depend on the naming
/// being explicit.
///
/// Cloning uses APFS copy-on-write via
/// ``CloneManager/clone(source:to:)``, so a 100 GB disk clones
/// in milliseconds — only bytes the clone later *writes* consume
/// host storage. Each clone gets a freshly regenerated machine
/// identifier.
struct CloneVMSheet: View {

    /// Name of the source VM we're cloning from.
    let source: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var destination: String = ""
    @State private var errorMessage: String?
    @State private var isCloning: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                sourceRow
                destinationRow
                infoRow
            }
            .padding(20)

            if let error = errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }

            Divider()
            buttonBar
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 260)
        .task(id: source) { preseedDestinationName() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Label("Clone Virtual Machine", systemImage: "doc.on.doc")
                .font(.headline)
            Spacer()
        }
        .padding(16)
    }

    private var sourceRow: some View {
        LabeledContent("Source") {
            Text(source)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var destinationRow: some View {
        LabeledContent("Clone name") {
            TextField("name", text: $destination)
                .textFieldStyle(.roundedBorder)
                .disableAutocorrection(true)
        }
    }

    private var infoRow: some View {
        Text(
            "APFS copy-on-write — the clone shares disk blocks with " +
            "'\(source)' and takes milliseconds. Each clone gets a " +
            "unique machine identifier so both VMs can run at the " +
            "same time without conflict."
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var buttonBar: some View {
        // Group the cancel + confirm pair in a single glass
        // container so they morph together on hover / press and
        // share one rendered material pane rather than stacking
        // two independent glass layers.
        GlassEffectContainer(spacing: 8) {
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .glassButton()
                    .keyboardShortcut(.cancelAction)
                Button("Clone") { performClone() }
                    .glassProminentButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone || isCloning)
            }
        }
        .padding(16)
    }

    // MARK: - Logic

    private var canClone: Bool {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && appState.vms[trimmed] == nil
    }

    /// Picks a default destination name that doesn't collide with
    /// an existing VM. Starts with `<source>-clone` and walks up
    /// `-clone-2`, `-clone-3`, … until a free slot is found.
    /// Runs once when the sheet appears for a given source.
    private func preseedDestinationName() {
        let base = "\(source)-clone"
        if appState.vms[base] == nil {
            destination = base
            return
        }
        var suffix = 2
        while appState.vms["\(base)-\(suffix)"] != nil {
            suffix += 1
        }
        destination = "\(base)-\(suffix)"
    }

    private func performClone() {
        let trimmed = destination.trimmingCharacters(in: .whitespaces)
        guard appState.vms[trimmed] == nil else {
            errorMessage = "A VM named '\(trimmed)' already exists."
            return
        }
        isCloning = true
        errorMessage = nil
        appState.cloneVM(source, to: trimmed)
        // `cloneVM` routes errors through `presentError`; a
        // successful clone adds the destination to `appState.vms`,
        // which is our cue to dismiss.
        if appState.vms[trimmed] != nil {
            dismiss()
        } else {
            isCloning = false
        }
    }
}
