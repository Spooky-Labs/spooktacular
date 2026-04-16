import SwiftUI
import SpooktacularKit

/// Post-create hardware editor.
///
/// Lets the user retune CPU / memory / disk on a stopped VM
/// without deleting and re-creating it. Locked while the VM is
/// running — `VirtualMachineBundle.writeSpec` updates the
/// on-disk `config.json` atomically, and `VirtualMachine`
/// reloads the spec on next `start()`.
///
/// Disk shrinking is intentionally prohibited — increasing a
/// sparse image is cheap, shrinking risks data loss. The disk
/// slider's lower bound is pinned to the current value.
struct HardwareEditor: View {

    let vmName: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var cpu: Int = 4
    @State private var memoryGB: Int = 8
    @State private var diskGB: Int = 64
    @State private var errorMessage: String?
    @State private var initialized: Bool = false

    private var bundle: VirtualMachineBundle? { appState.vms[vmName] }
    private var isRunning: Bool { appState.isRunning(vmName) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                if isRunning { runningHint }
                cpuRow
                memoryRow
                diskRow
            }
            .formStyle(.grouped)
            .disabled(isRunning)
            Divider()
            footer
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 340)
        .task(id: vmName) { loadInitialValues() }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Label("Hardware", systemImage: "cpu")
                .font(.headline)
            Spacer()
        }
        .padding(16)
    }

    private var runningHint: some View {
        Section {
            Label("Stop the workspace to edit hardware.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var cpuRow: some View {
        Section("CPU") {
            LabeledContent("Cores") {
                Stepper("\(cpu)", value: $cpu, in: 2...32)
                    .monospacedDigit()
            }
        }
    }

    private var memoryRow: some View {
        Section("Memory") {
            LabeledContent("GB") {
                Stepper("\(memoryGB)", value: $memoryGB, in: 4...128, step: 1)
                    .monospacedDigit()
            }
        }
    }

    private var diskRow: some View {
        Section("Disk") {
            LabeledContent("GB") {
                let floor = Int(bundle?.spec.diskSizeInGigabytes ?? 32)
                Stepper("\(diskGB)", value: $diskGB, in: floor...2048, step: 8)
                    .monospacedDigit()
            }
            Text("Disk size can only increase — shrinking risks data loss.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .glassButton()
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || !hasChanges)
        }
        .padding(16)
    }

    // MARK: - Logic

    private var hasChanges: Bool {
        guard let spec = bundle?.spec else { return false }
        return cpu != spec.cpuCount
            || UInt64(memoryGB) != spec.memorySizeInGigabytes
            || UInt64(diskGB) != spec.diskSizeInGigabytes
    }

    private func loadInitialValues() {
        guard !initialized, let spec = bundle?.spec else { return }
        cpu = spec.cpuCount
        memoryGB = Int(spec.memorySizeInGigabytes)
        diskGB = Int(spec.diskSizeInGigabytes)
        initialized = true
    }

    private func save() {
        guard let bundle else { return }
        let updated = bundle.spec.with(
            cpuCount: cpu,
            memorySizeInBytes: .gigabytes(UInt64(memoryGB)),
            diskSizeInBytes: .gigabytes(UInt64(diskGB))
        )
        do {
            try VirtualMachineBundle.writeSpec(updated, to: bundle.url)
            appState.loadVMs()   // pick up new spec
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
