import SwiftUI
import SpooktacularKit
import UniformTypeIdentifiers
import Darwin

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
    /// Source of the macOS install media. `.latest` asks Apple's
    /// signing service for the newest IPSW compatible with this
    /// host (the default, ~12 GB download); `.local` points at an
    /// IPSW already on disk. Offline, airgapped, and fleet-clone
    /// workflows live entirely in `.local`.
    @State private var ipswSource: IPSWSource = .latest
    @State private var localIpswPath: String = ""
    @State private var cpuCount: Double = 4
    @State private var memorySizeInGigabytes: Double = 8
    @State private var diskSizeInGigabytes: Double = 64
    @State private var displayCount = 1
    @State private var autoResizeDisplay = true
    /// The high-level network kind selected in the picker.
    /// Bridged mode reveals the ``bridgedInterface`` picker below.
    @State private var networkKind: NetworkKind = .nat
    @State private var bridgedInterface: String = ""
    @State private var audioEnabled = true
    @State private var microphoneEnabled = false
    @State private var clipboardSharingEnabled = true
    @State private var sharedFolders: [SharedFolderEntry] = []
    @State private var userDataPath = ""
    @State private var provisioningMode = ProvisioningMode.diskInject

    @State private var isCreating = false
    @State private var statusMessage = ""
    @State private var progress: Double = 0
    @State private var bytesReceived: Int64 = 0
    @State private var bytesTotal: Int64 = 0
    @State private var errorMessage: String?

    /// In-flight creation task, used by the Cancel button to
    /// interrupt the download / install loop and clean up the
    /// partial bundle.
    @State private var creationTask: Task<Void, Never>?

    /// Network selector modes. Separating ``NetworkMode`` (the
    /// domain value) from the picker's selection avoids leaking
    /// the associated interface name into the UI state space.
    private enum NetworkKind: String, Hashable, CaseIterable {
        case nat, bridged, isolated
    }

    /// macOS install-media source. Mirrors the CLI's
    /// `--from-ipsw latest|<path>` — an enum keeps the path string
    /// from being silently interpreted when the user is on
    /// "latest".
    private enum IPSWSource: String, Hashable, CaseIterable {
        case latest, local
    }

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
                    sourceRow
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
                Button("Cancel") { cancelOrDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close the sheet and cancel the in-flight download")
                    .accessibilityIdentifier(AccessibilityID.cancelButton)
                Spacer()
                if isCreating {
                    ProgressView().controlSize(.small)
                }
                Button("Create") {
                    let task = Task { await createVM() }
                    creationTask = task
                }
                .glassButton()
                .disabled(isCreating || !canCreate)
                .keyboardShortcut(.defaultAction)
                .help("Download the IPSW, install macOS, and register the bundle")
                .accessibilityIdentifier(AccessibilityID.createConfirmButton)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 640)
        .accessibilityIdentifier(AccessibilityID.createSheet)
    }

    /// Whether the Create button is eligible to fire. Requires a
    /// non-blank VM name and — when `.local` IPSW is selected —
    /// a non-blank path. Existence of the path is checked later
    /// inside `createVM()` so the user isn't blocked by a stale
    /// filesystem state while typing.
    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if ipswSource == .local {
            return !localIpswPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    // MARK: - Cancel / Dismiss

    /// Cancels the in-flight creation task if running, otherwise
    /// dismisses the sheet. Partial bundle cleanup happens in the
    /// `catch` branch of ``createVM()``.
    private func cancelOrDismiss() {
        if let task = creationTask {
            task.cancel()
            creationTask = nil
        } else {
            dismiss()
        }
    }

    // MARK: - Rows (two-column: control | explanation)

    private var nameRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Name").font(.headline).glassSectionHeader()
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

    private var sourceRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("macOS Source").font(.headline).glassSectionHeader()

                    Picker("Source", selection: $ipswSource) {
                        Text("Latest compatible").tag(IPSWSource.latest)
                        Text("Local IPSW file").tag(IPSWSource.local)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Choose where to get the macOS install media. 'Latest' downloads from Apple; 'Local' uses an IPSW you already have on disk.")

                    if ipswSource == .local {
                        HStack {
                            TextField("~/Downloads/macOS.ipsw", text: $localIpswPath)
                                .textFieldStyle(.roundedBorder)
                            Button("Browse…") { browseForIPSW() }
                        }
                    }
                }
            },
            explanation: ipswSourceExplanation
        )
    }

    private var ipswSourceExplanation: String {
        switch ipswSource {
        case .latest:
            return """
                Downloads the newest macOS IPSW compatible with \
                this host from Apple's signing service. Cached \
                under ~/.spooktacular/ipsw/ and deduplicated by \
                SHA-256, so subsequent VMs skip the download.
                """
        case .local:
            return """
                Installs from an IPSW already on disk — skip the \
                10–20 GB download. Useful for offline installs, \
                pinning to a known macOS build, or re-creating \
                VMs from a fleet-wide IPSW snapshot.
                """
        }
    }

    private var hardwareRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hardware").font(.headline).glassSectionHeader()

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
                        .accessibilityIdentifier(AccessibilityID.cpuStepper)
                        .help("Number of virtual CPU cores. Minimum 4, maximum is this Mac's logical core count.")
                        .accessibilityValue("\(Int(cpuCount)) CPU cores")
                    }

                    HStack {
                        Text("Memory")
                            .frame(width: 70, alignment: .leading)
                        Slider(value: $memorySizeInGigabytes, in: 4...64, step: 4)
                            .accessibilityIdentifier(AccessibilityID.memorySlider)
                            .help("Guest RAM in gigabytes. Allocated from your Mac's unified memory.")
                            .accessibilityValue("\(Int(memorySizeInGigabytes)) gigabytes RAM")
                        Text("\(Int(memorySizeInGigabytes)) GB")
                            .monospacedDigit()
                            .frame(width: 45, alignment: .trailing)
                    }

                    HStack {
                        Text("Disk")
                            .frame(width: 70, alignment: .leading)
                        Slider(value: $diskSizeInGigabytes, in: 32...500, step: 32)
                            .accessibilityIdentifier(AccessibilityID.diskSlider)
                            .help("Virtual disk size. APFS sparse — only host space the guest actually writes is consumed.")
                            .accessibilityValue("\(Int(diskSizeInGigabytes)) gigabytes disk")
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
                    Text("Display").font(.headline).glassSectionHeader()

                    Picker("Monitors", selection: $displayCount) {
                        Text("1 Display").tag(1)
                        Text("2 Displays").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.displayPicker)
                    .help("Number of virtual monitors attached to the guest. Each uses a Metal-accelerated GPU.")

                    Toggle("Auto-resize display", isOn: $autoResizeDisplay)
                        .help("Adjust the guest resolution automatically when you resize the window. Recommended for remote desktop.")
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
                    Text("Network").font(.headline).glassSectionHeader()

                    Picker("Mode", selection: $networkKind) {
                        Text("NAT (shared)").tag(NetworkKind.nat)
                        Text("Bridged (own IP)").tag(NetworkKind.bridged)
                        Text("Isolated (no network)").tag(NetworkKind.isolated)
                    }
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.networkPicker)
                    .help("Networking mode. Bridged requires the com.apple.vm.networking entitlement.")

                    if networkKind == .bridged {
                        Picker("Interface", selection: $bridgedInterface) {
                            ForEach(availableBridgedInterfaces(), id: \.self) { iface in
                                Text(iface).tag(iface)
                            }
                        }
                        .help("Host network interface to bridge onto. Typically en0 for Wi-Fi, en1 for Ethernet.")
                        .onAppear {
                            // Preselect the first interface if none chosen.
                            if bridgedInterface.isEmpty,
                               let first = availableBridgedInterfaces().first {
                                bridgedInterface = first
                            }
                        }
                    }
                }
            },
            explanation: networkExplanation
        )
    }

    /// Enumerates host network interface names via `getifaddrs`
    /// and returns the ones suitable for VM bridging (up, not
    /// loopback, has an IPv4 address).
    private func availableBridgedInterfaces() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [String] = []
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            let family = current.pointee.ifa_addr?.pointee.sa_family
            let isIPv4 = family == UInt8(AF_INET)
            if isUp, !isLoopback, isIPv4 {
                let name = String(cString: current.pointee.ifa_name)
                if !result.contains(name) { result.append(name) }
            }
            pointer = current.pointee.ifa_next
        }
        return result.sorted()
    }

    private var audioRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio & Sharing").font(.headline).glassSectionHeader()

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
                    Text("Shared Folders").font(.headline).glassSectionHeader()

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
                    Text("User Data Script").font(.headline).glassSectionHeader()

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
        switch networkKind {
        case .nat:
            "The VM accesses the internet through your Mac's connection. " +
            "The host can reach the guest via its DHCP-assigned IP."
        case .isolated:
            "The VM has no network interface. Use for secure builds " +
            "where network isolation is required. Host-guest " +
            "communication is still possible via the VirtIO socket."
        case .bridged:
            "The VM gets its own IP on your local network via the " +
            "chosen host interface. Requires the " +
            "com.apple.vm.networking entitlement."
        }
    }

    /// Converts the UI-local ``NetworkKind`` + bridged interface
    /// into the domain ``NetworkMode`` value the bundle expects.
    private func resolvedNetworkMode() -> NetworkMode {
        switch networkKind {
        case .nat: return .nat
        case .isolated: return .isolated
        case .bridged:
            return .bridged(interface: bridgedInterface.isEmpty ? "en0" : bridgedInterface)
        }
    }

    // MARK: - Status Bar

    @ViewBuilder
    private var statusBar: some View {
        VStack(spacing: 6) {
            if isCreating {
                ProgressView(value: progress)
                    .tint(.accentColor)
                    .accessibilityIdentifier(AccessibilityID.progressIndicator)
                    .accessibilityValue("\(Int(progress * 100)) percent")
                HStack {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.statusMessage)
                    Spacer()
                    if bytesTotal > 0 {
                        Text("\(byteString(bytesReceived)) / \(byteString(bytesTotal))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if let error = errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .glassCard(cornerRadius: 10)
    }

    private func byteString(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
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

    /// Opens an `NSOpenPanel` restricted to `.ipsw` files. The
    /// `.ipsw` UTType is synthesized on-the-fly from the filename
    /// extension since there is no registered conformance in the
    /// system UTType database — Apple's Virtualization.framework
    /// treats IPSWs by signature internally.
    ///
    /// Docs: https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/init(filenameextension:conformingto:)
    private func browseForIPSW() {
        let panel = NSOpenPanel()
        panel.title = "Select IPSW File"
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            localIpswPath = url.path
        }
    }

    @MainActor
    private func createVM() async {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        isCreating = true
        errorMessage = nil
        bytesReceived = 0
        bytesTotal = 0

        let spec = VirtualMachineSpecification(
            cpuCount: Int(cpuCount),
            memorySizeInBytes: .gigabytes(Int(memorySizeInGigabytes)),
            diskSizeInBytes: .gigabytes(Int(diskSizeInGigabytes)),
            displayCount: displayCount,
            networkMode: resolvedNetworkMode(),
            audioEnabled: audioEnabled,
            microphoneEnabled: microphoneEnabled,
            sharedFolders: sharedFolders.map {
                SharedFolder(hostPath: $0.hostPath, tag: $0.tag, readOnly: $0.readOnly)
            },
            autoResizeDisplay: autoResizeDisplay,
            clipboardSharingEnabled: clipboardSharingEnabled
        )

        let manager = RestoreImageManager(cacheDirectory: appState.ipswCacheDirectory)
        let bundleURL = (try? SpooktacularPaths.bundleURL(for: trimmedName))

        do {
            statusMessage = "Fetching restore image info…"
            progress = 0
            let restoreImage = try await manager.fetchLatestSupported()
            try Task.checkCancellation()
            let version = restoreImage.operatingSystemVersion
            statusMessage = "Found macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            progress = 0.05

            let ipswURL: URL
            if ipswSource == .local {
                // Apple's VZ framework needs the hardware model
                // from `fetchLatestSupported()` for bundle
                // creation even when the user supplies their
                // own IPSW, so we keep that call above and only
                // skip the download here. Mirrors the CLI's
                // branching in `Sources/spook/Commands/Create.swift`.
                let trimmedPath = localIpswPath.trimmingCharacters(in: .whitespaces)
                let expanded = (trimmedPath as NSString).expandingTildeInPath
                let candidate = URL(filePath: expanded)
                guard FileManager.default.fileExists(atPath: candidate.path) else {
                    errorMessage = "IPSW file not found at '\(expanded)'."
                    isCreating = false
                    creationTask = nil
                    return
                }
                ipswURL = candidate
                statusMessage = "Using local IPSW at \(candidate.lastPathComponent)…"
                progress = 0.5
            } else {
                statusMessage = "Downloading kernel and firmware…"
                ipswURL = try await manager.downloadIPSW(from: restoreImage) { snapshot in
                    Task { @MainActor in
                        bytesReceived = snapshot.bytesReceived
                        bytesTotal = snapshot.bytesTotal
                        progress = 0.05 + snapshot.fraction * 0.45
                        let pct = Int(snapshot.fraction * 100)
                        statusMessage = snapshot.resumed
                            ? "Resuming IPSW download (\(pct)%)…"
                            : "Downloading IPSW (\(pct)%)…"
                    }
                }
            }
            try Task.checkCancellation()

            statusMessage = "Writing base disk…"
            progress = 0.5
            let bundle = try manager.createBundle(
                named: trimmedName, in: appState.vmsDirectory,
                from: restoreImage, spec: spec
            )
            try Task.checkCancellation()

            statusMessage = "Installing macOS…"
            progress = 0.55
            try await manager.install(bundle: bundle, from: ipswURL) { fractionCompleted in
                Task { @MainActor in
                    progress = 0.55 + fractionCompleted * 0.45
                    statusMessage = "Installing macOS (\(Int(fractionCompleted * 100))%)…"
                }
            }

            appState.loadVMs()
            appState.selectedVM = trimmedName
            isCreating = false
            creationTask = nil
            dismiss()
        } catch is CancellationError {
            // User hit Cancel — remove any partial bundle so a
            // subsequent retry doesn't trip over it.
            if let url = bundleURL {
                try? FileManager.default.removeItem(at: url)
            }
            isCreating = false
            creationTask = nil
            progress = 0
            statusMessage = "Cancelled."
            dismiss()
        } catch {
            if let url = bundleURL {
                try? FileManager.default.removeItem(at: url)
            }
            let categorized = SpooktacularError.classify(error)
            errorMessage = "\(categorized.errorDescription ?? error.localizedDescription) \(categorized.suggestedAction)"
            isCreating = false
            creationTask = nil
            progress = 0
        }
    }
}
