import SwiftUI
@preconcurrency import Virtualization
import SpooktacularKit

/// Entry for a shared folder in the create form.
struct SharedFolderEntry: Identifiable {
    let id = UUID()
    var hostPath: String
    var tag: String
    var readOnly: Bool = false
}

/// A sheet for creating a new virtual machine.
///
/// Uses a two-column layout: controls on the left, explanations
/// on the right. Does NOT use SwiftUI `Form` (which breaks
/// TextField focus in macOS sheets). All controls are plain
/// SwiftUI views inside a `ScrollView`.
struct CreateVMSheet: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    @State private var name = ""
    @State private var cpuCount: Double = 4
    @State private var memorySizeInGigabytes: Double = 8
    @State private var diskSizeInGigabytes: Double = 64
    @State private var displayCount = 1
    @State private var autoResizeDisplay = true
    @State private var networkMode = NetworkMode.nat
    @State private var audioEnabled = true
    @State private var microphoneEnabled = false
    @State private var clipboardSharingEnabled = true
    @State private var sharedFolders: [SharedFolderEntry] = []
    @State private var userDataPath = ""
    @State private var provisioningMode = ProvisioningMode.diskInject

    @State private var isCreating = false
    @State private var statusMessage = ""
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("New Virtual Machine")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            // Two-column scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nameRow
                    hardwareRow
                    displayRow
                    networkRow
                    audioRow
                    sharedFoldersRow
                    userDataRow
                }
                .padding(24)
            }

            // Status bar
            if isCreating || errorMessage != nil {
                Divider()
                statusBar
            }

            // Button bar
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if isCreating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Create") { Task { await createVM() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 640)
    }

    // MARK: - Rows (two-column: control | explanation)

    private var nameRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.headline)
                    TextField("my-vm", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AccessibilityID.vmNameField)
                }
            },
            explanation: """
                A unique name for this virtual machine. Used in the \
                CLI as 'spook start <name>' and shown in Kubernetes \
                as the resource name.
                """
        )
    }

    private var hardwareRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hardware").font(.headline)

                    HStack {
                        Text("CPU")
                            .frame(width: 70, alignment: .leading)
                        Stepper(
                            value: $cpuCount,
                            in: 4...Double(ProcessInfo.processInfo.processorCount),
                            step: 1
                        ) {
                            Text("\(Int(cpuCount)) cores")
                                .monospacedDigit()
                        }
                    }

                    HStack {
                        Text("Memory")
                            .frame(width: 70, alignment: .leading)
                        Slider(value: $memorySizeInGigabytes, in: 4...64, step: 4)
                        Text("\(Int(memorySizeInGigabytes)) GB")
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }

                    HStack {
                        Text("Disk")
                            .frame(width: 70, alignment: .leading)
                        Slider(value: $diskSizeInGigabytes, in: 32...500, step: 32)
                        Text("\(Int(diskSizeInGigabytes)) GB")
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }
                }
            },
            explanation: """
                macOS VMs require at least 4 CPU cores. Memory is \
                allocated from your Mac's unified RAM. The disk uses \
                APFS sparse storage — it only consumes host disk \
                space as the guest writes data.
                """
        )
    }

    private var displayRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Display").font(.headline)

                    Picker("Monitors", selection: $displayCount) {
                        Text("1 Display").tag(1)
                        Text("2 Displays").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle("Auto-resize display", isOn: $autoResizeDisplay)
                }
            },
            explanation: """
                Each display is backed by a Metal-accelerated GPU. \
                Auto-resize adjusts the guest resolution when you \
                resize the window — essential for remote desktop use.
                """
        )
    }

    private var networkRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Network").font(.headline)

                    Picker("Mode", selection: $networkMode) {
                        Text("NAT (shared)").tag(NetworkMode.nat)
                        Text("Isolated (no network)").tag(NetworkMode.isolated)
                    }
                    .labelsHidden()
                }
            },
            explanation: networkExplanation
        )
    }

    private var audioRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio & Sharing").font(.headline)

                    Toggle("Speaker output", isOn: $audioEnabled)
                    Toggle("Microphone input", isOn: $microphoneEnabled)
                    Toggle("Clipboard sharing", isOn: $clipboardSharingEnabled)
                }
            },
            explanation: """
                Audio uses VirtIO sound devices. Clipboard sharing \
                is only supported for Linux guests; macOS guests \
                do not support clipboard synchronization through \
                the Virtualization framework.
                """
        )
    }

    private var sharedFoldersRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shared Folders").font(.headline)

                    ForEach($sharedFolders) { $folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder.hostPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(folder.readOnly ? "ro" : "rw")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                sharedFolders.removeAll { $0.id == folder.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        addSharedFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "plus")
                    }
                }
            },
            explanation: """
                Shared folders appear in the guest at \
                /Volumes/My Shared Files/. Use them to pass \
                build artifacts, training data, or configuration \
                files between host and guest without networking.
                """
        )
    }

    private var userDataRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("User Data Script").font(.headline)

                    HStack {
                        TextField("~/setup.sh", text: $userDataPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseForScript() }
                    }

                    if !userDataPath.isEmpty {
                        Picker("Method", selection: $provisioningMode) {
                            ForEach(ProvisioningMode.allCases, id: \.self) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }
                }
            },
            explanation: userDataPath.isEmpty
                ? """
                    A shell script that runs automatically after the \
                    VM boots. Used to install tools, configure CI \
                    runners, set up ML environments, or automate \
                    any first-boot setup.
                    """
                : provisioningMode.explanation
        )
    }

    // MARK: - Two-Column Row Builder

    private func row<C: View>(
        @ViewBuilder control: () -> C,
        explanation: String
    ) -> some View {
        HStack(alignment: .top, spacing: 24) {
            control()
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 200, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Network Explanation

    private var networkExplanation: String {
        switch networkMode {
        case .nat:
            "The VM accesses the internet through your Mac's connection. " +
            "The host can reach the guest via its DHCP-assigned IP."
        case .isolated:
            "The VM has no network interface. Use for secure builds " +
            "where network isolation is required. Host-guest " +
            "communication is still possible via the VirtIO socket."
        case .bridged:
            "The VM gets its own IP on your local network. Requires " +
            "the com.apple.vm.networking entitlement."
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            if isCreating {
                ProgressView(value: progress)
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func addSharedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Folder to Share"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            let tag = url.lastPathComponent
            sharedFolders.append(
                SharedFolderEntry(hostPath: url.path, tag: tag)
            )
        }
    }

    private func browseForScript() {
        let panel = NSOpenPanel()
        panel.title = "Select User Data Script"
        panel.allowedContentTypes = [.shellScript, .plainText, .data]
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            userDataPath = url.path
        }
    }

    @MainActor
    private func createVM() async {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        isCreating = true
        errorMessage = nil

        let spec = VirtualMachineSpecification(
            cpuCount: Int(cpuCount),
            memorySizeInBytes: .gigabytes(Int(memorySizeInGigabytes)),
            diskSizeInBytes: .gigabytes(Int(diskSizeInGigabytes)),
            displayCount: displayCount,
            networkMode: networkMode,
            audioEnabled: audioEnabled,
            microphoneEnabled: microphoneEnabled,
            sharedFolders: sharedFolders.map {
                SharedFolder(hostPath: $0.hostPath, tag: $0.tag, readOnly: $0.readOnly)
            },
            autoResizeDisplay: autoResizeDisplay,
            clipboardSharingEnabled: clipboardSharingEnabled
        )

        let manager = RestoreImageManager(cacheDirectory: appState.ipswCacheDirectory)

        do {
            statusMessage = "Fetching restore image info…"
            progress = 0
            let restoreImage = try await manager.fetchLatestSupported()
            let version = restoreImage.operatingSystemVersion
            statusMessage = "Found macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            progress = 0.05

            statusMessage = "Downloading IPSW…"
            let ipswURL = try await manager.downloadIPSW(from: restoreImage) { fractionCompleted in
                Task { @MainActor in
                    progress = 0.05 + fractionCompleted * 0.45
                    statusMessage = "Downloading IPSW (\(Int(fractionCompleted * 100))%)…"
                }
            }

            statusMessage = "Creating VM bundle…"
            progress = 0.5
            let bundle = try manager.createBundle(
                named: name, in: appState.vmsDirectory,
                from: restoreImage, spec: spec
            )

            statusMessage = "Installing macOS…"
            progress = 0.55
            try await manager.install(bundle: bundle, from: ipswURL) { fractionCompleted in
                Task { @MainActor in
                    progress = 0.55 + fractionCompleted * 0.45
                    statusMessage = "Installing macOS (\(Int(fractionCompleted * 100))%)…"
                }
            }

            appState.loadVMs()
            appState.selectedVM = name
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isCreating = false
            progress = 0
        }
    }
}
