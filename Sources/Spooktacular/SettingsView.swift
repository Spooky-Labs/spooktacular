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
    /// operators who configure via a device-management profile
    /// or launchd plist don't get silently overridden by a
    /// per-user GUI toggle.
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
                    // Lantern carries "needs attention" in the
                    // Apparition palette — the semantic in-progress
                    // gold, never the wisp accent.
                    .foregroundStyle(Apparition.lantern)
                    .font(.caption)
                }
            }

            Section("Learn more") {
                if let dataAtRestURL {
                    Link(
                        "docs/DATA_AT_REST.md — OWASP ASVS mapping, threat model, verification",
                        destination: dataAtRestURL
                    )
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshEffective)
        .onChange(of: policy) { _, _ in refreshEffective() }
    }

    /// `URL(string:)` only fails for malformed input, which this
    /// literal is not — but we still route through an `Optional`
    /// rather than force-unwrapping, so a future typo degrades to
    /// a missing link instead of a crash.
    private var dataAtRestURL: URL? {
        URL(string: "https://github.com/Spooky-Labs/spooktacular/blob/main/docs/DATA_AT_REST.md")
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
                        // Pulses only while the XPC round-trip is in
                        // flight. `ping()` sets `.pinging` before the
                        // `await client.ping()` and clears it in the
                        // continuation, so this is a genuine async
                        // window persona A can watch — an indefinite
                        // pulse bound to real in-progress state, not
                        // decoration.
                        .symbolEffect(.pulse, isActive: status == .pinging)
                        // Hover delight: one discrete bounce on
                        // pointer entry — composes with the pulse
                        // above (independent effects). Reduce-
                        // Motion-gated inside the modifier.
                        .hoverSymbolBounce()
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
            // Vital = alive / healthy in the Apparition palette.
            .foregroundStyle(Apparition.vital)
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
