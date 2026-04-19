import AppKit
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
    @State private var audioEnabled: Bool = true
    @State private var microphoneEnabled: Bool = false
    @State private var sharedFolders: [SharedFolderEntry] = []
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
                audioRow
                sharedFoldersRow
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

    /// Audio output + optional microphone capture. Both toggle
    /// the corresponding `VZVirtioSoundDevice*StreamConfiguration`
    /// on the VM's config during next `start()`. The form is
    /// already `.disabled` while the VM is running (the whole
    /// section inherits it from the outer Form), so the user
    /// can't flip these under a live machine — matches Apple's
    /// "VM device configuration is immutable after startup"
    /// guarantee from
    /// https://developer.apple.com/documentation/virtualization/vzvirtualmachineconfiguration.
    private var audioRow: some View {
        Section("Audio") {
            Toggle("Speaker output", isOn: $audioEnabled)
                .help("Route guest audio to the host's default output device. Needed for web video (YouTube), music, and VM audio alerts.")
            Toggle("Microphone input", isOn: $microphoneEnabled)
                .disabled(!audioEnabled)
                .help("Attach the host's microphone to the guest. Requires audio to be enabled.")
            if !audioEnabled {
                Text("Disabling audio removes the VirtIO sound device from the guest. Safe for headless compute workloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shared folders (VirtIO FS) attached to the VM. VirtIO FS
    /// device configuration is immutable after startup — per
    /// Apple's `VZVirtualMachineConfiguration` contract — so the
    /// whole Form is already `.disabled` while running. The
    /// shared-folders section therefore doesn't need its own
    /// locked-state treatment.
    ///
    /// Docs: https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration
    private var sharedFoldersRow: some View {
        Section("Shared Folders") {
            if sharedFolders.isEmpty {
                Text("No folders shared. Guest mounts appear under /Volumes/My Shared Files/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($sharedFolders) { $folder in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.hostPath)
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("tag: \(folder.tag)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Read only", isOn: $folder.readOnly)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .help("When on, the guest sees this folder as mounted read-only. Useful for source trees the guest shouldn't mutate.")
                        Button(role: .destructive) {
                            sharedFolders.removeAll { $0.id == folder.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Remove this shared folder. Takes effect next start.")
                    }
                }
            }

            Button {
                addSharedFolder()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .glassProminentButton()
                .keyboardShortcut(.defaultAction)
                .disabled(isRunning || !hasChanges)
        }
        .padding(16)
    }

    // MARK: - Logic

    private var hasChanges: Bool {
        guard let spec = bundle?.spec else { return false }
        let existing = spec.sharedFolders.map {
            SharedFolderEntry(hostPath: $0.hostPath, tag: $0.tag, readOnly: $0.readOnly)
        }
        return cpu != spec.cpuCount
            || UInt64(memoryGB) != spec.memorySizeInGigabytes
            || UInt64(diskGB) != spec.diskSizeInGigabytes
            || audioEnabled != spec.audioEnabled
            || microphoneEnabled != spec.microphoneEnabled
            || !sharedFoldersMatch(existing, sharedFolders)
    }

    /// Compares two `SharedFolderEntry` arrays ignoring their
    /// per-instance UUIDs. Without this, freshly-added-and-removed
    /// entries would always register as a "change" because the
    /// form-state IDs don't round-trip through the domain spec.
    private func sharedFoldersMatch(
        _ lhs: [SharedFolderEntry],
        _ rhs: [SharedFolderEntry]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if a.hostPath != b.hostPath
                || a.tag != b.tag
                || a.readOnly != b.readOnly {
                return false
            }
        }
        return true
    }

    private func loadInitialValues() {
        guard !initialized, let spec = bundle?.spec else { return }
        cpu = spec.cpuCount
        memoryGB = Int(spec.memorySizeInGigabytes)
        diskGB = Int(spec.diskSizeInGigabytes)
        audioEnabled = spec.audioEnabled
        microphoneEnabled = spec.microphoneEnabled
        sharedFolders = spec.sharedFolders.map {
            SharedFolderEntry(hostPath: $0.hostPath, tag: $0.tag, readOnly: $0.readOnly)
        }
        initialized = true
    }

    /// Presents an `NSOpenPanel` restricted to directories and
    /// appends the chosen folder to the shared-folders list. The
    /// guest tag defaults to the folder name — operators who want
    /// a different VirtIO FS mount tag can edit it post-creation
    /// by removing + re-adding, which is rare enough not to
    /// warrant a nested edit UI here.
    ///
    /// Docs: https://developer.apple.com/documentation/appkit/nsopenpanel
    private func addSharedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder to Share"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            sharedFolders.append(
                SharedFolderEntry(
                    hostPath: url.path,
                    tag: url.lastPathComponent
                )
            )
        }
    }

    private func save() {
        guard let bundle else { return }
        let folders = sharedFolders.map {
            SharedFolder(hostPath: $0.hostPath, tag: $0.tag, readOnly: $0.readOnly)
        }
        let updated = bundle.spec.with(
            cpuCount: cpu,
            memorySizeInBytes: .gigabytes(UInt64(memoryGB)),
            diskSizeInBytes: .gigabytes(UInt64(diskGB)),
            audioEnabled: audioEnabled,
            microphoneEnabled: microphoneEnabled,
            sharedFolders: folders
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
