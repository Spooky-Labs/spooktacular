import SwiftUI
import SpooktacularKit
import UniformTypeIdentifiers
import Virtualization
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
    /// Guest operating system.  Branches the create flow
    /// between the macOS installer (IPSW → `VZMacOSInstaller`)
    /// and the Linux installer (ISO → `VZEFIBootLoader` +
    /// `VZUSBMassStorageDeviceConfiguration`).  Mirrors the
    /// CLI's `--os macos|linux` flag on `spooktacular create`.
    @State private var guestOS: GuestOS = .macOS
    /// Source of the macOS install media. `.latest` asks Apple's
    /// signing service for the newest IPSW compatible with this
    /// host (the default, ~12 GB download); `.local` points at an
    /// IPSW already on disk. Offline, airgapped, and fleet-clone
    /// workflows live entirely in `.local`.
    @State private var ipswSource: IPSWSource = .latest
    @State private var localIpswPath: String = ""
    /// Path to the Linux installer ISO when
    /// ``guestOS`` is ``GuestOS/linux``.  Copied into the
    /// bundle at create time so the install flow owns its
    /// own media (no dangling references to the source file
    /// if the user later moves it).  Mirrors the CLI's
    /// `--installer-iso` flag.
    @State private var installerISOPath: String = ""

    /// Expose Rosetta 2 to the Linux guest as a virtio-fs
    /// share.  Only shown when ``guestOS`` is
    /// ``GuestOS/linux``; disabled when Rosetta is not
    /// available on the host.  Mirrors the CLI's
    /// `--rosetta` flag.
    @State private var rosettaEnabled: Bool = false
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

    /// Which built-in provisioning template (if any) to run on
    /// first boot. Mirrors the CLI's `--github-runner`,
    /// `--openclaw`, and `--remote-desktop` flags.
    @State private var template: ProvisioningTemplate = .none

    /// `owner/repo` slug for the GitHub Actions runner template.
    @State private var githubRepo: String = ""

    /// Keychain account under service `com.spooktacular.github`
    /// where the runner registration token lives. Keychain is the
    /// only accepted token source — env-var / flag / file paths
    /// were removed pre-1.0 to keep the PAT out of `ps`,
    /// `launchctl print`, and plaintext-on-disk exposures.
    @State private var githubKeychainAccount: String = ""

    /// When true, the runner exits after one job — used by
    /// ephemeral CI pools that reclone a clean VM per run.
    @State private var ephemeralRunner: Bool = false

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

    /// Built-in first-boot provisioning templates. `.custom`
    /// surfaces the existing script picker + provisioning-method
    /// chooser; `.none` skips provisioning entirely and leaves
    /// the VM at its vanilla install state.
    private enum ProvisioningTemplate: String, Hashable, CaseIterable {
        case none, githubRunner, openclaw, remoteDesktop, custom

        var label: String {
            switch self {
            case .none: return "None (manual setup)"
            case .githubRunner: return "GitHub Actions Runner"
            case .openclaw: return "OpenClaw AI Agent"
            case .remoteDesktop: return "Remote Desktop (VNC)"
            case .custom: return "Custom Script"
            }
        }

        var explanation: String {
            switch self {
            case .none:
                return """
                    Leave the VM unprovisioned. The guest boots into a \
                    pristine macOS install; configure it interactively \
                    or attach a user-data script later with \
                    `spook start <name> --user-data <path>`.
                    """
            case .githubRunner:
                return """
                    Registers the VM as a self-hosted GitHub Actions \
                    runner on first boot. Downloads the latest \
                    darwin-arm64 runner, configures it with your repo \
                    + registration token (read from the Keychain — \
                    env-var / CLI-flag / file paths were removed \
                    pre-1.0), and starts it in unattended mode.
                    """
            case .openclaw:
                return """
                    Installs Node.js + the OpenClaw gateway daemon on \
                    first boot so the VM acts as a sandboxed agent \
                    host. Pass API keys via a Shared Folder — keeps \
                    secrets out of the provisioning script.
                    """
            case .remoteDesktop:
                return """
                    Enables macOS Screen Sharing / VNC on first boot. \
                    The VM reports its VNC URL in the system log so \
                    `spook ip` + a VNC client is all you need to \
                    connect from another Mac, iPad, or PC.
                    """
            case .custom:
                return """
                    Run a shell script you provide on first boot. \
                    Disk-inject runs before the guest's Setup \
                    Assistant via a LaunchDaemon; SSH runs after \
                    first boot over the network.
                    """
            }
        }
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
            // Runs once when the sheet appears; if
            // `AppState.pendingCreateIpswPath` is set (e.g. from
            // "Create VM from image" in the image detail view),
            // pre-seed the source + path so the user doesn't
            // have to re-browse for the same file they just
            // added. Consumed on read so a later open starts
            // clean.
            .onAppear {
                if let preset = appState.pendingCreateIpswPath {
                    ipswSource = .local
                    localIpswPath = preset
                    appState.pendingCreateIpswPath = nil
                }
            }

            Divider()

            // Two-column scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    nameRow
                    osRow
                    switch guestOS {
                    case .macOS:
                        sourceRow
                    case .linux:
                        installerISORow
                        rosettaRow
                    }
                    hardwareRow
                    displayRow
                    networkRow
                    audioRow
                    sharedFoldersRow
                    // Provisioning templates are macOS-only
                    // for now (OpenClaw + RemoteDesktop are
                    // Apple-framework templates, GitHub
                    // Runner's LaunchDaemon injection targets
                    // APFS).  Linux VMs get a vanilla install
                    // and can be provisioned later via SSH or
                    // cloud-init.
                    if guestOS == .macOS {
                        provisioningRow
                    }
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
        // Propagate the `.switch` style to every `Toggle` in the
        // sheet via environment inheritance — checkboxes read as
        // old-style Mac form controls; switches match the
        // Liquid-Glass sliding-thumb idiom and the app's other
        // boolean surfaces.
        .toggleStyle(.switch)
    }

    /// Whether the Create button is eligible to fire. A non-blank
    /// VM name is required; `.local` IPSW layers on a non-blank
    /// path; and the GitHub Actions template layers on
    /// `owner/repo` + Keychain account so users can't arm the
    /// Create button into a guaranteed failure (wrong path or
    /// Keychain miss). Existence of the local IPSW path itself
    /// is checked inside `createVM()` so the user isn't blocked
    /// by transient filesystem state while typing.
    private var canCreate: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch guestOS {
        case .macOS:
            if ipswSource == .local,
               localIpswPath.trimmingCharacters(in: .whitespaces).isEmpty {
                return false
            }
            switch template {
            case .githubRunner:
                return !githubRepo.trimmingCharacters(in: .whitespaces).isEmpty
                    && !githubKeychainAccount.trimmingCharacters(in: .whitespaces).isEmpty
            default:
                return true
            }
        case .linux:
            return !installerISOPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
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

    private var osRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Guest OS").font(.headline).glassSectionHeader()
                    Picker("Guest OS", selection: $guestOS) {
                        Text("macOS").tag(GuestOS.macOS)
                        Text("Linux").tag(GuestOS.linux)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("macOS uses Apple's IPSW installer; Linux boots an installer ISO via EFI.")
                }
            },
            explanation: guestOSExplanation
        )
    }

    private var guestOSExplanation: String {
        switch guestOS {
        case .macOS:
            return """
                Installs a macOS guest from an Apple IPSW. \
                Uses VZMacOSInstaller under the hood and \
                produces a Mac-style VM bundle with hardware \
                model, aux storage, and NVRAM.
                """
        case .linux:
            return """
                Boots a Linux installer ISO via EFI firmware \
                (VZEFIBootLoader) and installs onto a fresh \
                sparse disk. Supports any UEFI-bootable ARM64 \
                distribution (Fedora, Ubuntu, Debian, …).
                """
        }
    }

    private var installerISORow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Installer ISO").font(.headline).glassSectionHeader()
                    HStack {
                        TextField("~/Downloads/Fedora-Workstation-Live-43.aarch64.iso", text: $installerISOPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") { browseForInstallerISO() }
                    }
                }
            },
            explanation: """
                Path to a UEFI-bootable ARM64 installer ISO. \
                Copied into the VM bundle at create time, then \
                exposed to the guest firmware as a USB mass \
                storage device so EFI's boot manager finds it \
                first. Remove the ISO from the bundle after \
                the guest OS is installed.
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

    private var provisioningRow: some View {
        row(
            control: {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Provisioning").font(.headline).glassSectionHeader()

                    Picker("Template", selection: $template) {
                        ForEach(ProvisioningTemplate.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .help("Pick a built-in first-boot template or provide a custom script.")

                    switch template {
                    case .none, .openclaw, .remoteDesktop:
                        EmptyView()
                    case .githubRunner:
                        githubRunnerFields
                    case .custom:
                        customScriptFields
                    }
                }
            },
            explanation: template.explanation
        )
    }

    @ViewBuilder
    private var githubRunnerFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("owner/repo", text: $githubRepo)
                .textFieldStyle(.roundedBorder)
                .help("GitHub repository in owner/repo form (e.g. acme-inc/platform).")

            TextField("Keychain account", text: $githubKeychainAccount)
                .textFieldStyle(.roundedBorder)
                .help("Account name under Keychain service com.spooktacular.github. Add the token first: security add-generic-password -s com.spooktacular.github -a <account> -w <token> -U")

            Toggle("Ephemeral (one job per VM)", isOn: $ephemeralRunner)
                .help("Runner exits after one job; pair with Snapshot-restore-before-start or re-create for clean per-job environments.")
        }
    }

    @ViewBuilder
    private var customScriptFields: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                Text(provisioningMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
    /// Rosetta toggle + availability hint.  Disables the
    /// toggle (and forces it off) when the host reports
    /// Rosetta as unavailable, so the user can't arm a
    /// flag that'll silently no-op at VM start.  The
    /// availability check hits the framework directly
    /// rather than caching a value — Rosetta can transition
    /// from uninstalled to installed if the user runs
    /// `softwareupdate --install-rosetta` while this sheet
    /// is open.
    private var rosettaRow: some View {
        let available = VZLinuxRosettaDirectoryShare.availability == .installed
        return row(
            control: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Rosetta 2").font(.headline).glassSectionHeader()
                    Toggle("Enable Rosetta in guest", isOn: $rosettaEnabled)
                        .disabled(!available)
                        .onChange(of: available) { _, newValue in
                            if !newValue { rosettaEnabled = false }
                        }
                    if !available {
                        Text("Rosetta is not installed on this Mac. Run `softwareupdate --install-rosetta` in Terminal, then reopen this sheet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            },
            explanation: """
                Exposes Apple's Rosetta 2 translator to the \
                Linux guest via a virtio-fs share. After \
                install, x86_64 ELF binaries run natively in \
                the guest without QEMU — great for Docker \
                cross-arch builds, CI runners handling \
                legacy binaries, or running x86-only tools \
                on Apple silicon.
                """
        )
    }

    /// Opens an `NSOpenPanel` restricted to disk-image files.
    /// `UTType.diskImage` (`public.disk-image`) is the system
    /// UTI that covers ISO, DMG, IMG, and related mountable
    /// formats; its subtype hierarchy includes
    /// `public.iso-image` so `.iso` files pass the filter.
    /// We also synthesize an explicit `.iso` UTType from the
    /// filename extension so distros that ship ISOs without
    /// the expected UTI metadata still appear enabled in the
    /// picker.
    ///
    /// Docs:
    /// - [UTType.diskImage](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/diskimage)
    /// - [UTType(filenameExtension:conformingTo:)](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype/init(filenameextension:conformingto:))
    private func browseForInstallerISO() {
        let panel = NSOpenPanel()
        panel.title = "Select Linux Installer ISO"
        panel.prompt = "Select"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var allowed: [UTType] = [.diskImage]
        if let isoType = UTType(filenameExtension: "iso", conformingTo: .diskImage) {
            allowed.append(isoType)
        }
        panel.allowedContentTypes = allowed
        if panel.runModal() == .OK, let url = panel.url {
            installerISOPath = url.path
        }
    }

    private func browseForIPSW() {
        let panel = NSOpenPanel()
        panel.title = "Select IPSW File"
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            localIpswPath = url.path
        }
    }

    /// Generates the provisioning script (if any) and injects it
    /// into the bundle via ``DiskInjector``. For template-backed
    /// scripts we always use `disk-inject` — the guest hasn't
    /// booted yet, so SSH isn't reachable. Custom scripts honour
    /// the user's `provisioningMode` selection.
    ///
    /// Script cleanup policy matches
    /// `Sources/spooktacular-cli/Commands/Create.swift`: template-generated
    /// scripts live under `~/Library/Caches/com.spooktacular/`
    /// and are removed post-injection to shrink the on-disk
    /// window for the GitHub registration token.
    @MainActor
    private func provisionBundle(_ bundle: VirtualMachineBundle) async throws {
        let scriptURL: URL?
        let ownsScript: Bool
        (scriptURL, ownsScript) = try resolveProvisionScript()

        guard let script = scriptURL else { return }

        statusMessage = "Injecting first-boot script…"
        progress = 1.0

        // `hdiutil attach/detach` + APFS mount is synchronous and
        // takes ~2-3s. Move it off the main actor so the progress
        // bar keeps animating.
        try await Task.detached(priority: .userInitiated) {
            try DiskInjector.inject(script: script, into: bundle)
        }.value

        if ownsScript {
            // `ScriptFile.cleanup` is best-effort — failures are
            // logged by the shared path and don't abort the flow.
            try? ScriptFile.cleanup(scriptURL: script)
        }
    }

    /// Resolves the provisioning script for the selected template
    /// and returns `(url, ownsScript)` — the second tuple member
    /// tells the caller whether to delete the file after use.
    /// Templates we generate live in a cache directory and should
    /// be cleaned; user-supplied scripts are left alone.
    private func resolveProvisionScript() throws -> (URL?, Bool) {
        switch template {
        case .none:
            return (nil, false)
        case .githubRunner:
            let repo = githubRepo.trimmingCharacters(in: .whitespaces)
            let account = githubKeychainAccount.trimmingCharacters(in: .whitespaces)
            let token = try GitHubTokenResolver.resolve(keychainAccount: account)
            let url = try GitHubRunnerTemplate.generate(
                repo: repo,
                token: token,
                ephemeral: ephemeralRunner
            )
            return (url, true)
        case .openclaw:
            return (try OpenClawTemplate.generate(), true)
        case .remoteDesktop:
            return (try RemoteDesktopTemplate.generate(), true)
        case .custom:
            let trimmed = userDataPath.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return (nil, false) }
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                throw CreateVMSheetError.userDataNotFound(path: expanded)
            }
            return (URL(filePath: expanded), false)
        }
    }

    /// Build a Linux VM bundle: empty disk + installer ISO +
    /// EFI NVRAM + machine identifier.  No IPSW, no
    /// `VZMacOSInstaller`, no post-install provisioning
    /// (first boot is interactive into the distro's
    /// installer).  Mirrors
    /// `runLinuxCreate` in the CLI.
    @MainActor
    private func createLinuxVM(
        trimmedName: String,
        spec: VirtualMachineSpecification,
        bundleURL: URL?
    ) async {
        statusMessage = "Preparing Linux VM bundle…"
        progress = 0

        let trimmedISOPath = installerISOPath.trimmingCharacters(in: .whitespaces)
        let expanded = (trimmedISOPath as NSString).expandingTildeInPath
        let isoURL = URL(filePath: expanded)
        guard FileManager.default.fileExists(atPath: isoURL.path) else {
            errorMessage = "Installer ISO not found at '\(expanded)'."
            isCreating = false
            creationTask = nil
            return
        }

        guard let targetBundleURL = bundleURL ?? (try? SpooktacularPaths.bundleURL(for: trimmedName)) else {
            errorMessage = "Could not resolve VM bundle path for '\(trimmedName)'."
            isCreating = false
            creationTask = nil
            return
        }

        do {
            try Task.checkCancellation()

            // Bundle skeleton — writes config.json,
            // metadata.json, and (because
            // spec.guestOS == .linux) the empty EFI NVRAM
            // file + generic machine identifier.
            let bundle = try VirtualMachineBundle.create(
                at: targetBundleURL,
                spec: spec
            )
            progress = 0.2
            statusMessage = "Allocating \(Int(diskSizeInGigabytes)) GB disk…"

            // Disk allocation goes through the shared
            // `DiskImageAllocator` which prefers ASIF
            // (Apple Sparse Image Format) and falls back to
            // RAW on older hosts.  See its docs for the
            // portability / APFS tradeoff — ASIF-backed
            // `.spook.vm` bundles survive cross-filesystem
            // transfers without materializing zeros.
            let diskURL = targetBundleURL.appendingPathComponent(
                VirtualMachineBundle.diskImageFileName
            )
            let diskFormat = try await DiskImageAllocator.create(
                at: diskURL,
                sizeInBytes: spec.diskSizeInBytes
            )
            statusMessage = "Allocated \(diskFormat.rawValue.uppercased()) disk…"
            try Task.checkCancellation()

            progress = 0.5
            statusMessage = "Copying installer ISO…"
            // FileManager.copyItem picks up APFS clonefile
            // semantics when source and destination live on
            // the same volume — the 2–4 GB copy is typically
            // near-instant.
            try FileManager.default.copyItem(at: isoURL, to: bundle.installerISOURL)
            progress = 0.9
            statusMessage = "Finalizing…"

            appState.loadVMs()
            appState.selectedVM = trimmedName
            isCreating = false
            creationTask = nil
            dismiss()
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: targetBundleURL)
            isCreating = false
            creationTask = nil
            progress = 0
            statusMessage = "Cancelled."
            dismiss()
        } catch {
            try? FileManager.default.removeItem(at: targetBundleURL)
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription {
                let suggestion = localized.recoverySuggestion.map { " \($0)" } ?? ""
                errorMessage = description + suggestion
            } else {
                errorMessage = error.localizedDescription
            }
            isCreating = false
            creationTask = nil
            progress = 0
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
            clipboardSharingEnabled: clipboardSharingEnabled,
            guestOS: guestOS,
            rosettaEnabled: guestOS == .linux ? rosettaEnabled : false
        )

        let bundleURL = (try? SpooktacularPaths.bundleURL(for: trimmedName))

        // Linux branch is short-and-straightforward —
        // allocate the bundle, sparse-truncate the disk,
        // copy the installer ISO.  No IPSW download, no
        // `VZMacOSInstaller`, no provisioning (yet).  Mirrors
        // `runLinuxCreate` in
        // `Sources/spooktacular-cli/Commands/Create.swift`.
        if guestOS == .linux {
            await createLinuxVM(trimmedName: trimmedName, spec: spec, bundleURL: bundleURL)
            return
        }

        let manager = RestoreImageManager(cacheDirectory: appState.ipswCacheDirectory)

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
                // branching in `Sources/spooktacular-cli/Commands/Create.swift`.
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
            let bundle = try await manager.createBundle(
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

            // Provisioning phase — generate the template script
            // (or resolve the user-supplied one) and inject it via
            // the same code path the CLI uses. Executed after
            // install so the guest's data volume exists; disk
            // injection mounts the freshly-populated APFS
            // container and drops a LaunchDaemon that fires on
            // first boot.
            try Task.checkCancellation()
            try await provisionBundle(bundle)

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
            // Keychain misses and user-data lookup failures carry
            // their own recoverySuggestion — render both lines so
            // the user gets the copy-paste-ready `security add-
            // generic-password` fix verbatim from
            // `GitHubTokenError`. Other errors still route through
            // SpooktacularError's classifier for consistent tone.
            if let localized = error as? LocalizedError,
               let description = localized.errorDescription {
                let suggestion = localized.recoverySuggestion.map { " \($0)" } ?? ""
                errorMessage = description + suggestion
            } else {
                let categorized = SpooktacularError.classify(error)
                errorMessage = "\(categorized.errorDescription ?? error.localizedDescription) \(categorized.suggestedAction)"
            }
            isCreating = false
            creationTask = nil
            progress = 0
        }
    }
}

/// Diagnostics specific to the Create VM sheet. Most errors
/// surfaced in this flow come from framework types (Keychain,
/// VZ, filesystem) — this enum only covers UI-validation failures
/// we can't attribute elsewhere.
private enum CreateVMSheetError: LocalizedError {
    case userDataNotFound(path: String)
    case diskAllocationFailed(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .userDataNotFound(let path):
            return "User-data script not found at '\(path)'."
        case .diskAllocationFailed(let path, let reason):
            return "Failed to allocate sparse disk image at '\(path)': \(reason)."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .userDataNotFound:
            return "Pick an existing shell script with the Browse… button, or remove the template selection."
        case .diskAllocationFailed:
            return "Check free disk space and that the bundles directory is writable, then try again."
        }
    }
}
