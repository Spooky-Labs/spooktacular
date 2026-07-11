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

    /// Reduce Motion gate. Every animated flourish in this sheet
    /// binds to a state change, and all of them collapse to an
    /// instant (non-animated) state application when the user
    /// asks the system to reduce motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// Three-way control for installing Spooktacular Guest
    /// Tools into the guest's `/Applications/`. Default
    /// matches the zero-friction "just works" semantics —
    /// clipboard + guest-agent API come online at first login
    /// without the user having to click anything. Only shown
    /// in the UI for macOS guests; Linux guests ignore it.
    @State private var guestToolsInstall: GuestToolsInstallMode = .installed
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

    /// Surface for pre-dispatch validation errors — Keychain
    /// miss on the GitHub-runner template, missing user-data
    /// script, etc. Once the request ships to AppState the
    /// sheet dismisses immediately; any post-dispatch failure
    /// lands on the sidebar's `PendingVMRow`, not here.
    @State private var errorMessage: String?

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
                    // Display headings speak in SF Pro Rounded —
                    // the Apparition type voice.
                    .fontDesign(.rounded)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)
            // Runs once when the sheet appears. Two mutually-
            // exclusive pre-seed paths set by "Create VM from
            // image" in the image detail view — one for macOS
            // IPSWs, one for Linux ISOs — so the sheet lands
            // on the right guest-OS pane + prefilled path and
            // the user doesn't have to re-browse for the same
            // file they just selected. Both are consumed on
            // read so a subsequent "New VM" open starts clean.
            .onAppear {
                if let ipsw = appState.pendingCreateIpswPath {
                    guestOS = .macOS
                    ipswSource = .local
                    localIpswPath = ipsw
                    appState.pendingCreateIpswPath = nil
                } else if let iso = appState.pendingCreateISOPath {
                    guestOS = .linux
                    installerISOPath = iso
                    appState.pendingCreateISOPath = nil
                }
            }

            Divider()

            // `Form(formStyle: .grouped)` on macOS 26 renders
            // Liquid Glass-backed section cards + places Section
            // footers BELOW the content (like Apple's System
            // Settings). Input controls — Picker, Stepper,
            // Slider, Toggle, TextField — auto-adopt the
            // Liquid Glass chrome inside a grouped Form.
            //
            // Previously this sheet rolled its own two-column
            // layout with glass-chip headers + side
            // explanations, which:
            //   1. overrode the system Form styling, losing
            //      auto-glass on pickers / steppers / sliders;
            //   2. pushed long descriptions into a 200pt side
            //      column that truncated awkwardly;
            //   3. diverged from every other macOS app's
            //      expected "new VM / new …" sheet layout.
            // Converting to Form eliminates all three issues
            // and removes ~100 lines of layout plumbing.
            Form {
                Section {
                    TextField("my-vm", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(AccessibilityID.vmNameField)
                } header: {
                    RitualGlassHeader(title: "Name", complete: nameSectionComplete)
                } footer: {
                    Text("A unique name for this virtual machine. Used in the CLI as 'spook start <name>' and shown in Kubernetes as the resource name.")
                }

                Section {
                    Picker("Guest OS", selection: $guestOS) {
                        Text("macOS").tag(GuestOS.macOS)
                        Text("Linux").tag(GuestOS.linux)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("macOS uses Apple's IPSW installer; Linux boots an installer ISO via EFI.")
                } header: {
                    // Always sealed — the segmented picker can't
                    // hold an invalid value.
                    RitualGlassHeader(title: "Guest OS", complete: true)
                } footer: {
                    Text(guestOSExplanation)
                }

                switch guestOS {
                case .macOS:
                    Section {
                        sourceControl
                    } header: {
                        RitualGlassHeader(
                            title: "macOS Source",
                            complete: macOSSourceSectionComplete
                        )
                    } footer: {
                        Text("Choose where to get the macOS install media. 'Latest' downloads from Apple; 'Local' uses an IPSW you already have on disk.")
                    }
                case .linux:
                    Section {
                        HStack {
                            TextField(
                                "~/Downloads/Fedora-Workstation-Live-43.aarch64.iso",
                                text: $installerISOPath
                            )
                            .textFieldStyle(.roundedBorder)
                            Button("Browse…") { browseForInstallerISO() }
                        }
                    } header: {
                        RitualGlassHeader(
                            title: "Installer ISO",
                            complete: isoSectionComplete
                        )
                    } footer: {
                        Text("Path to a UEFI-bootable ARM64 installer ISO. Copied into the VM bundle at create time, then exposed to the guest firmware as a USB mass storage device so EFI's boot manager finds it first. Remove the ISO from the bundle after the guest OS is installed.")
                    }
                    rosettaSection
                }

                Section {
                    hardwareControls
                } header: {
                    // Steppers/sliders are range-clamped — always valid.
                    RitualGlassHeader(title: "Hardware", complete: true)
                } footer: {
                    Text("macOS VMs require at least 4 CPU cores. Memory is allocated from your Mac's unified RAM. The disk uses APFS sparse storage — it only consumes host disk space as the guest writes data.")
                }

                Section {
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
                } header: {
                    RitualGlassHeader(title: "Display", complete: true)
                } footer: {
                    Text("Each display is backed by a Metal-accelerated GPU. Auto-resize adjusts the guest resolution when you resize the window — essential for remote desktop use.")
                }

                Section {
                    networkControls
                } header: {
                    RitualGlassHeader(
                        title: "Network",
                        complete: networkSectionComplete
                    )
                } footer: {
                    Text(networkExplanation)
                }

                Section {
                    Toggle("Speaker output", isOn: $audioEnabled)
                    Toggle("Microphone input", isOn: $microphoneEnabled)
                    Toggle("Clipboard sharing", isOn: $clipboardSharingEnabled)
                } header: {
                    RitualGlassHeader(title: "Audio & Sharing", complete: true)
                } footer: {
                    Text("Audio uses VirtIO sound devices. Clipboard sharing enables the SPICE virtio-serial port; enabling Guest Tools below activates the guest side of the bridge.")
                }

                if guestOS == .macOS {
                    Section {
                        Picker("Guest Tools", selection: $guestToolsInstall) {
                            ForEach(GuestToolsInstallMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    } header: {
                        RitualGlassHeader(title: "Guest Tools", complete: true)
                    } footer: {
                        Text(guestToolsInstall.helpText)
                    }
                }

                Section {
                    sharedFoldersControls
                } header: {
                    // Optional section — an empty list is a valid choice.
                    RitualGlassHeader(title: "Shared Folders", complete: true)
                } footer: {
                    Text("Shared folders appear in the guest at /Volumes/My Shared Files/. Use them to pass build artifacts, training data, or configuration files between host and guest without networking.")
                }

                if guestOS == .macOS {
                    Section {
                        provisioningControls
                    } header: {
                        RitualGlassHeader(
                            title: "Provisioning",
                            complete: provisioningSectionComplete
                        )
                    } footer: {
                        Text(template.explanation)
                    }
                }
            }
            .formStyle(.grouped)

            // Inline error — pre-dispatch validation failures
            // only (Keychain miss, missing user-data script).
            // Post-dispatch progress lives on the sidebar's
            // pending row.
            if errorMessage != nil {
                Divider()
                errorBar
            }

            // Button bar. Cancel just dismisses; Create builds
            // the request, hands it to AppState, and dismisses
            // immediately — the actual long-running pipeline
            // (IPSW download, install, disk inject) runs on the
            // AppState-owned Task and publishes progress to the
            // `pendingCreations` dict. The sidebar renders a
            // row per entry with progress + status, so the
            // user keeps the library available throughout.
            Divider()
            // Explicit interior spacing (10) LARGER than the
            // container spacing (8): per Apple's
            // GlassEffectContainer semantics, container spacing
            // >= interior stack spacing merges adjacent shapes at
            // rest — the fused-blob failure mode. (The Spacer
            // keeps this pair far apart anyway; the explicit
            // value makes the contract auditable, matching the
            // app's other sheet footers.)
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 10) {
                    Button("Cancel") { dismiss() }
                        .glassButton()
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier(AccessibilityID.cancelButton)
                    Spacer()
                    // `submitCreate()` dismisses the sheet on
                    // successful dispatch and leaves it open
                    // (with `errorMessage` set) on validation
                    // failure so the user can fix Keychain /
                    // path issues without losing the form
                    // state they just typed.
                    Button {
                        submitCreate()
                    } label: {
                        Label("Create", systemImage: "plus")
                            // Hover delight: the plus bounces once
                            // when the pointer enters the primary
                            // action. Reduce-Motion-gated inside
                            // the modifier.
                            .hoverSymbolBounce()
                    }
                    .glassProminentButton()
                    // The ONE wisp glassProminent on this
                    // surface — the accent marks the primary
                    // action and nothing else; the prominent
                    // style itself carries the wisp, so no
                    // manual `.tint` here.
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
                    .help("Create the VM. Download + install run in the background; progress shows in the sidebar.")
                    .accessibilityIdentifier(AccessibilityID.createConfirmButton)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        // Ground the sheet in the Apparition palette (material +
        // faint night wash), and spring the pre-dispatch error
        // bar in/out on the `errorMessage` state change.
        .apparitionSheetGround()
        .animation(reduceMotion ? nil : Apparition.spring, value: errorMessage)
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

    // MARK: - Ritual section validity
    //
    // Presentation-only mirrors of `canCreate`'s per-section
    // requirements. Each drives the completion seal in its
    // section header — sections whose controls can't hold an
    // invalid value pass `complete: true` at the call site and
    // render a statically sealed header.

    /// The Name section seals once a non-blank name exists.
    private var nameSectionComplete: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The macOS Source section seals on "Latest" (no input
    /// needed) or once a local IPSW path has been provided.
    private var macOSSourceSectionComplete: Bool {
        ipswSource == .latest
            || !localIpswPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Installer ISO section seals once a path is present.
    private var isoSectionComplete: Bool {
        !installerISOPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The Network section seals unless bridged mode is armed
    /// with no host interface to bridge onto.
    private var networkSectionComplete: Bool {
        networkKind != .bridged || !bridgedInterface.isEmpty
    }

    /// The Provisioning section seals when the selected template
    /// has everything it needs: the GitHub-runner template wants
    /// `owner/repo` + a Keychain account, the custom template
    /// wants a script path, and the rest are self-contained.
    private var provisioningSectionComplete: Bool {
        switch template {
        case .none, .openclaw, .remoteDesktop:
            return true
        case .githubRunner:
            return !githubRepo.trimmingCharacters(in: .whitespaces).isEmpty
                && !githubKeychainAccount.trimmingCharacters(in: .whitespaces).isEmpty
        case .custom:
            return !userDataPath.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // MARK: - Section controls (plain — Form wraps)

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

    @ViewBuilder
    private var sourceControl: some View {
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

    @ViewBuilder
    private var hardwareControls: some View {
        HStack {
            Text("CPU").frame(width: 70, alignment: .leading)
            Stepper(
                value: $cpuCount,
                in: 4...Double(ProcessInfo.processInfo.processorCount),
                step: 1
            ) {
                // Machine-speak: tabular digits, and the count
                // rolls (`numericText`) as the stepper fires.
                // Docs: <https://developer.apple.com/documentation/SwiftUI/ContentTransition/numericText(value:)>
                Text("\(Int(cpuCount)) cores")
                    .monospacedDigit()
                    .contentTransition(.numericText(value: cpuCount))
                    .animation(reduceMotion ? nil : Apparition.quick, value: cpuCount)
            }
            .accessibilityIdentifier(AccessibilityID.cpuStepper)
            .help("Number of virtual CPU cores. Minimum 4, maximum is this Mac's logical core count.")
            .accessibilityValue("\(Int(cpuCount)) CPU cores")
        }
        HStack {
            Text("Memory").frame(width: 70, alignment: .leading)
            Slider(value: $memorySizeInGigabytes, in: 4...64, step: 4)
                .accessibilityIdentifier(AccessibilityID.memorySlider)
                .help("Guest RAM in gigabytes. Allocated from your Mac's unified memory.")
                .accessibilityValue("\(Int(memorySizeInGigabytes)) gigabytes RAM")
            Text("\(Int(memorySizeInGigabytes)) GB")
                .monospacedDigit()
                .contentTransition(.numericText(value: memorySizeInGigabytes))
                .animation(
                    reduceMotion ? nil : Apparition.quick,
                    value: memorySizeInGigabytes
                )
                .frame(width: 45, alignment: .trailing)
        }
        HStack {
            Text("Disk").frame(width: 70, alignment: .leading)
            Slider(value: $diskSizeInGigabytes, in: 32...500, step: 32)
                .accessibilityIdentifier(AccessibilityID.diskSlider)
                .help("Virtual disk size. APFS sparse — only host space the guest actually writes is consumed.")
                .accessibilityValue("\(Int(diskSizeInGigabytes)) gigabytes disk")
            Text("\(Int(diskSizeInGigabytes)) GB")
                .monospacedDigit()
                .contentTransition(.numericText(value: diskSizeInGigabytes))
                .animation(
                    reduceMotion ? nil : Apparition.quick,
                    value: diskSizeInGigabytes
                )
                .frame(width: 45, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var networkControls: some View {
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
                if bridgedInterface.isEmpty,
                   let first = availableBridgedInterfaces().first {
                    bridgedInterface = first
                }
            }
        }
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

    @ViewBuilder
    private var sharedFoldersControls: some View {
        ForEach($sharedFolders) { $folder in
            HStack {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(folder.hostPath).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(folder.readOnly ? "ro" : "rw")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    sharedFolders.removeAll { $0.id == folder.id }
                } label: {
                    Image(systemName: "minus.circle")
                        // Interactive control — the symbol bounces
                        // once on pointer entry (Reduce-Motion-gated).
                        .hoverSymbolBounce()
                }
                .buttonStyle(.plain)
            }
        }
        Button {
            addSharedFolder()
        } label: {
            Label("Add Folder…", systemImage: "plus")
                .hoverSymbolBounce()
        }
    }

    @ViewBuilder
    private var provisioningControls: some View {
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

    // MARK: - Error Bar

    @ViewBuilder
    private var errorBar: some View {
        if let error = errorMessage {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Reading surface (validation prose), so material —
                // not glass. The chip's corners resolve concentric
                // with the sheet's 26pt container (declared by
                // `apparitionSheetGround()`), sharing center points
                // with the sheet corners instead of hardcoding a
                // small radius; `minimum:` keeps the corner from
                // squaring off if the chip ever lands flush with
                // the container edge.
                .background(
                    .regularMaterial,
                    in: ConcentricRectangle(
                        corners: .concentric(minimum: 10.0),
                        isUniform: true
                    )
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
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
    @ViewBuilder
    private var rosettaSection: some View {
        let available = VZLinuxRosettaDirectoryShare.availability == .installed
        Section {
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
        } header: {
            // The toggle self-corrects when Rosetta is missing —
            // the section can't hold an invalid value.
            RitualGlassHeader(title: "Rosetta 2", complete: true)
        } footer: {
            Text("Exposes Apple's Rosetta 2 translator to the Linux guest via a virtio-fs share. After install, x86_64 ELF binaries run natively in the guest without QEMU — great for Docker cross-arch builds, CI runners handling legacy binaries, or running x86-only tools on Apple silicon.")
        }
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

    /// Resolves the provisioning script for the selected template
    /// and returns `(url, ownsScript)` — the second tuple member
    /// tells the caller whether to delete the file after use.
    /// Templates we generate live in a cache directory and should
    /// be cleaned; user-supplied scripts are left alone.
    ///
    /// The GitHub-runner template does **not** produce a script
    /// here — see ``resolveRunnerRequest()``. Resolving its
    /// Keychain token and rendering the runner script at
    /// sheet-submit time would mint a registration token up to
    /// hours before the VM finishes installing macOS; GitHub
    /// registration tokens expire after one hour. AppState's
    /// create pipeline mints the token late instead, mirroring
    /// `spook create --github-runner`.
    private func resolveProvisionScript() throws -> (URL?, Bool) {
        switch template {
        case .none, .githubRunner:
            return (nil, false)
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

    /// Validates and builds the ``RunnerRequest`` carried in the
    /// creation request when ``template`` is ``ProvisioningTemplate/githubRunner``.
    ///
    /// Only validates shape (non-blank fields, `owner/repo` form
    /// via ``RunnerRequest``'s initializer) — the Keychain lookup
    /// and registration-token mint happen later, in
    /// `AppState.runMacOSCreate`, seconds before the VM boots.
    ///
    /// - Returns: `nil` for every template other than
    ///   ``ProvisioningTemplate/githubRunner``.
    private func resolveRunnerRequest() throws -> RunnerRequest? {
        guard template == .githubRunner else { return nil }
        return try RunnerRequest(
            repo: githubRepo,
            keychainAccount: githubKeychainAccount,
            ephemeral: ephemeralRunner
        )
    }

    // MARK: - Submit

    /// Builds the `VirtualMachineSpecification` from the sheet's
    /// bindings, hands off the request to ``AppState``, and
    /// dismisses. The long-running pipeline (IPSW download,
    /// install, disk inject — or Linux disk + ISO copy) runs on
    /// AppState's Task and publishes progress to
    /// ``AppState/pendingCreations``; the sidebar renders a row
    /// per entry so the user can keep working with other VMs
    /// while this one builds.
    ///
    /// Pre-dispatch validation errors (Keychain miss on the
    /// GitHub-runner template, missing user-data script, etc.)
    /// keep the sheet open with ``errorMessage`` populated.
    /// Everything after successful dispatch is AppState's
    /// problem.
    private func submitCreate() {
        errorMessage = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

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
            rosettaEnabled: guestOS == .linux ? rosettaEnabled : false,
            guestToolsInstall: guestOS == .macOS ? guestToolsInstall : .disabled
        )

        switch guestOS {
        case .linux:
            let request = AppState.LinuxCreationRequest(
                name: trimmedName,
                spec: spec,
                installerISOPath: installerISOPath
            )
            appState.beginCreateLinuxVM(request)
            dismiss()
        case .macOS:
            do {
                let (userScriptURL, ownsUserScript) = try resolveProvisionScript()
                let runnerSpec = try resolveRunnerRequest()
                let request = AppState.MacOSCreationRequest(
                    name: trimmedName,
                    spec: spec,
                    ipswSource: ipswSource == .local ? .local : .latest,
                    localIpswPath: localIpswPath,
                    userScriptURL: userScriptURL,
                    ownsUserScript: ownsUserScript,
                    runnerSpec: runnerSpec
                )
                appState.beginCreateMacOSVM(request)
                dismiss()
            } catch {
                if let localized = error as? LocalizedError,
                   let description = localized.errorDescription {
                    let suggestion = localized.recoverySuggestion.map { " \($0)" } ?? ""
                    errorMessage = description + suggestion
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Apparition sheet chrome (shared by the creation-flow sheets)

/// A section header for the creation ritual: the section title
/// plus a completion seal that draws itself on the moment the
/// section's requirements are met.
///
/// The seal is a `checkmark.seal` tinted ``Apparition/vital``
/// (the "alive / valid" semantic color — never the wisp accent)
/// inserted with the DrawOn symbol transition and removed with
/// DrawOff, so a section visibly "unseals" if the user blanks a
/// required field again.
///
/// Docs — `SymbolEffectTransition` "applies the Appear,
/// Disappear, DrawOn or DrawOff symbol animation to symbol
/// images within the inserted or removed view hierarchy":
/// - <https://developer.apple.com/documentation/SwiftUI/SymbolEffectTransition>
/// - <https://developer.apple.com/documentation/Symbols/SymbolEffect/drawOn>
/// - <https://developer.apple.com/documentation/Symbols/SymbolEffect/drawOff>
///
/// Motion contract: the transition binds to the `complete` state
/// flip (SwiftUI applies no transition on the sheet's initial
/// render, so always-complete sections show a static seal), and
/// Reduce Motion nils the animation so the seal simply appears.
///
/// Used by ``CreateVMSheet``, ``CloneVMSheet``, and
/// ``AddImageSheet`` so the three creation-flow sheets read as
/// one ritual; it lives here because this file hosts the richest
/// use.
struct RitualSectionHeader: View {

    /// The section title — rendered exactly like the plain
    /// `Text` header it replaces.
    let title: String

    /// Whether the section's requirements are currently met.
    let complete: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if complete {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(Apparition.vital)
                    .imageScale(.small)
                    .transition(
                        AsymmetricTransition(
                            insertion: .symbolEffect(.drawOn),
                            removal: .symbolEffect(.drawOff)
                        )
                    )
                    .accessibilityLabel("Section complete")
            }
        }
        // Bind the seal's insertion/removal to the validity flip;
        // `nil` under Reduce Motion applies the change instantly.
        .animation(reduceMotion ? nil : Apparition.spring, value: complete)
    }
}

/// A ``RitualSectionHeader`` floated on a Liquid Glass capsule
/// chip — the Form-header presentation ``CreateVMSheet`` uses.
///
/// Section-header chips in the creation sheets are chrome, not
/// content: they hover over the sheet ground announcing each step
/// of the ritual, so they carry `.glassEffect(.regular, in:
/// .capsule)` (capsules stay capsules — a pill needs no concentric
/// resolution). Each chip is spatially isolated — one per Form
/// section, nowhere near another glass surface — so there is
/// deliberately no `GlassEffectContainer`: nothing sits close
/// enough to blend, and at-rest merging is impossible.
///
/// File-scoped (`private`) on purpose: ``AddImageSheet`` inlines
/// the same modifier chain at its call sites rather than importing
/// a shared helper, keeping `GlassModifiers.swift` untouched.
private struct RitualGlassHeader: View {

    /// The section title, forwarded to ``RitualSectionHeader``.
    let title: String

    /// Whether the section's requirements are currently met.
    let complete: Bool

    var body: some View {
        RitualSectionHeader(title: title, complete: complete)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Grounds a sheet in the Apparition palette: a standard system
/// material biased with a faint night/fog wash.
///
/// This is a content-layer treatment — deliberately **not**
/// Liquid Glass, which the HIG reserves for floating controls.
/// The wash layers ``Apparition/night1`` at low opacity over
/// `.thinMaterial`, biasing the system sheet background toward
/// the Night (dark) / Fog (light) grounds without replacing it.
///
/// It also declares the sheet as a 26pt continuous rounded
/// **container shape**, so every nested `ConcentricRectangle`
/// (error chips, floating panes) resolves a corner radius whose
/// center point is shared with the sheet's own corners — the
/// macOS 26 concentric-geometry contract. `containerShape(_:)`
/// only declares geometry; the system still clips the sheet
/// window itself.
private struct ApparitionSheetGroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                Rectangle()
                    .fill(.thinMaterial)
                    .overlay(Apparition.night1.opacity(0.25))
                    .ignoresSafeArea()
            }
            .containerShape(.rect(cornerRadius: 26))
    }
}

extension View {
    /// Applies the shared Apparition sheet ground — system
    /// material plus a faint night wash (no content-layer glass)
    /// — and declares the 26pt concentric container geometry for
    /// nested `ConcentricRectangle` chips.
    func apparitionSheetGround() -> some View {
        modifier(ApparitionSheetGroundModifier())
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
