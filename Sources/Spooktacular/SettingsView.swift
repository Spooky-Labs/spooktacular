import SwiftUI
import SpooktacularInfrastructureApple

/// The application settings view.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            SecuritySettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }

            NetworkFilterSettingsView()
                .tabItem { Label("Network Filter", systemImage: "network.badge.shield.half.filled") }

            VMHelperSettingsView()
                .tabItem { Label("VM Helper", systemImage: "cpu") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - General

struct GeneralSettingsView: View {

    private let storagePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".spooktacular")
        .path

    var body: some View {
        Form {
            Section("Data Directory") {
                LabeledContent("VM Storage") {
                    Text(storagePath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("VM storage directory")
                .accessibilityValue(storagePath)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Security

/// Security preferences — currently the bundle-protection policy
/// selector. See `docs/DATA_AT_REST.md` for the threat model the
/// picker corresponds to.
///
/// The bound `@AppStorage` value feeds back into
/// `BundleProtection.recommendedPolicy` via its UserDefaults tier,
/// which both the GUI and the `spook` CLI consult. So a change
/// made here takes effect on the next bundle write from either
/// surface without a restart.
struct SecuritySettingsView: View {

    /// Three-way policy choice: `"auto"` defers to form-factor
    /// detection; `"cufua"` forces CUFUA everywhere; `"none"`
    /// disables the protection. `SPOOKTACULAR_BUNDLE_PROTECTION`
    /// env var, when set, overrides this setting at runtime —
    /// operators who configure via MDM / launchd plist don't
    /// get silently overridden by a per-user GUI toggle.
    @AppStorage(BundleProtection.userDefaultsKey)
    private var policy: String = "auto"

    /// The recommendation we'd apply right now given the current
    /// env + UserDefaults + host. Refreshed on every settings
    /// open so the label is always current.
    @State private var effectivePolicy: BundleProtection.Policy = .autoDesktop
    @State private var effectiveClass: FileProtectionType = .none

    var body: some View {
        Form {
            Section {
                Picker("VM bundle protection", selection: $policy) {
                    Text("Automatic (recommended)").tag("auto")
                    Text("Protected — require login after boot").tag("cufua")
                    Text("Off — readable by pre-login daemons").tag("none")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityLabel("VM bundle protection policy")
            } header: {
                Text("Data at rest")
            } footer: {
                description
            }

            Section("Effective right now") {
                LabeledContent("Policy") {
                    Text(effectivePolicy.label)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Class") {
                    Text(effectiveClass.displayName)
                        .font(.system(.body, design: .monospaced))
                }
                if envOverrideActive {
                    Label(
                        "SPOOKTACULAR_BUNDLE_PROTECTION is set — it overrides this setting until unset.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    .font(.caption)
                }
            }

            Section("Learn more") {
                Link(
                    "docs/DATA_AT_REST.md — OWASP ASVS mapping, threat model, verification",
                    destination: URL(string: "https://github.com/Spooky-Labs/spooktacular/blob/main/docs/DATA_AT_REST.md")!
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshEffective)
        .onChange(of: policy) { _, _ in refreshEffective() }
    }

    @ViewBuilder
    private var description: some View {
        switch policy {
        case "cufua":
            Text(
                "Bundles are protected until you unlock this Mac once after reboot. "
                + "Defeats the 'stolen laptop with a compromised FileVault recovery key' "
                + "attack. Existing bundles stay unprotected until you run "
                + "`spook bundle protect --all`."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        case "none":
            Text(
                "Bundles are readable by any process running as you — including daemons "
                + "that start before login. Use this only on headless fleets where "
                + "pre-login daemons need bundle access."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        default:
            Text(
                "Detects whether this Mac is a laptop (battery present) and protects bundles "
                + "accordingly — CUFUA on laptops, off on desktops / EC2 Mac hosts. The "
                + "recommended setting for most users."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var envOverrideActive: Bool {
        ProcessInfo.processInfo.environment["SPOOKTACULAR_BUNDLE_PROTECTION"] != nil
    }

    private func refreshEffective() {
        let (cls, pol) = BundleProtection.recommendedPolicy()
        effectiveClass = cls
        effectivePolicy = pol
    }
}

// MARK: - Network Filter

/// Installs / updates the Spooktacular Network Filter system
/// extension that enforces per-tenant egress policies
/// (Track F''). See
/// ``SpooktacularInfrastructureApple/SystemExtensionActivator``
/// for the underlying Apple APIs; this view is the surface
/// that drives it.
///
/// Three states covered:
///
/// 1. **Idle** — user hasn't asked to install yet; button
///    reads "Install Network Filter" and describes the one-
///    time approval step.
/// 2. **Waiting for approval** — activation request accepted,
///    system is showing (or about to show) the Privacy &
///    Security prompt. View prompts the user to open System
///    Settings.
/// 3. **Installed / failed** — terminal status with a
///    follow-up action ("Re-install" if it failed, "Apply
///    Policies" if it succeeded — deep links to the egress CLI).
struct NetworkFilterSettingsView: View {

    enum Status: Equatable {
        case idle
        case requesting
        case needsApproval
        case installed
        case willCompleteAfterReboot
        case failed(String)
    }

    @State private var status: Status = .idle

    /// Apple exposes the extension via Privacy & Security →
    /// Extensions → Endpoint Security (actually, for NE
    /// content filters, the sanctioned UI is System Settings
    /// → Network → Filters once installed, and the approval
    /// prompt arrives via Privacy & Security). The deep-link
    /// URL below jumps to the approval-extension pane.
    private let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllowExtensionsBlocked"
    )!

    var body: some View {
        Form {
            Section {
                statusView
            } header: {
                Text("Status")
            } footer: {
                Text(
                    "The Spooktacular Network Filter is a macOS system extension. "
                    + "It enforces the per-VM egress policies you configure with "
                    + "`spooktacular egress set` and `spooktacular egress apply`. "
                    + "Installing is a one-time action — macOS requires you to "
                    + "approve the extension in System Settings → Privacy & Security."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button(action: install) {
                    Label(actionTitle, systemImage: "shield.lefthalf.filled.badge.checkmark")
                }
                .disabled(status == .requesting)

                if case .needsApproval = status {
                    Button("Open System Settings → Privacy & Security") {
                        NSWorkspace.shared.open(privacySettingsURL)
                    }
                }
            }

            Section("Learn more") {
                Link(
                    "Apple — Content Filter Providers",
                    destination: URL(string: "https://developer.apple.com/documentation/networkextension/filtering-network-traffic")!
                )
                .font(.caption)
                Link(
                    "docs/EGRESS_POLICY.md — policy model + CLI reference",
                    destination: URL(string: "https://github.com/Spooky-Labs/spooktacular/blob/main/docs/EGRESS_POLICY.md")!
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Label("Not installed", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .requesting:
            Label {
                Text("Submitting activation request…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .needsApproval:
            Label(
                "Waiting for approval in System Settings → Privacy & Security",
                systemImage: "hand.raised"
            )
            .foregroundStyle(.orange)
        case .installed:
            Label("Installed and enforcing policies", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        case .willCompleteAfterReboot:
            Label("Installed — reboot required to activate", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .failed(let message):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Installation failed").bold()
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        }
    }

    private var actionTitle: String {
        switch status {
        case .idle: "Install Network Filter"
        case .requesting: "Installing…"
        case .needsApproval: "Re-submit Activation"
        case .installed: "Re-install / Update"
        case .willCompleteAfterReboot: "Re-submit"
        case .failed: "Retry Install"
        }
    }

    private func install() {
        status = .requesting
        let activator = SystemExtensionActivator()
        Task { @MainActor in
            for await event in activator.activate() {
                switch event {
                case .needsUserApproval:     status = .needsApproval
                case .installed:             status = .installed
                case .willCompleteAfterReboot: status = .willCompleteAfterReboot
                case .failed(let error):     status = .failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - VM Helper

/// Track J diagnostics. Pings the bundled
/// ``SpooktacularInfrastructureApple/VMHelperClient`` and
/// reports the helper's PID + version, proving the main
/// app ↔ helper XPC boundary is live.
///
/// This panel exists so session 1's "shared helper
/// boundary" is visibly working without needing to wait
/// for real VM ops to move behind it. When later commits
/// route start/stop/pause/resume through the helper, this
/// view stays as a diagnostic backstop.
struct VMHelperSettingsView: View {

    enum Status: Equatable {
        case idle
        case pinging
        case ready(pid: Int32, version: String)
        case failed(String)
    }

    @State private var status: Status = .idle

    var body: some View {
        Form {
            Section {
                statusRow
                Button(action: ping) {
                    Label("Ping Helper", systemImage: "bolt.horizontal")
                }
                .disabled(status == .pinging)
            } header: {
                Text("Helper Process")
            } footer: {
                Text(
                    "The VM Helper is a bundled XPC service that runs Virtualization.framework "
                    + "in a separate process. A crash in the helper shows up here as a failed "
                    + "ping instead of taking down the main app."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch status {
        case .idle:
            Label("Not probed", systemImage: "circle")
                .foregroundStyle(.secondary)
        case .pinging:
            Label {
                Text("Pinging…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .ready(let pid, let version):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Helper responding").bold()
                    Text("pid \(pid) · version \(version)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .foregroundStyle(.green)
        case .failed(let message):
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ping failed").bold()
                    Text(message)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.red)
        }
    }

    private func ping() {
        status = .pinging
        Task { @MainActor in
            let client = VMHelperClient()
            do {
                let result = try await client.ping()
                status = .ready(pid: result.pid, version: result.version)
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Policy labels

extension BundleProtection.Policy {
    /// Human-readable label for the "Effective right now" row.
    var label: String {
        switch self {
        case .overrideNone:            "Env: off"
        case .overrideCUFUA:           "Env: CUFUA"
        case .overrideSettingsNone:    "Settings: off"
        case .overrideSettingsCUFUA:   "Settings: CUFUA"
        case .autoLaptop:              "Auto: laptop → CUFUA"
        case .autoDesktop:             "Auto: desktop → off"
        }
    }
}
