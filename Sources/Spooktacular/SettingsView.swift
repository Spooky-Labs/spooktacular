import SwiftUI
import SpookInfrastructureApple

/// The application settings view.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            SecuritySettingsView()
                .tabItem { Label("Security", systemImage: "lock.shield") }
        }
        .frame(width: 520, height: 340)
    }
}

// MARK: - General

struct GeneralSettingsView: View {

    private let storagePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".spooktacular")
        .path

    var body: some View {
        Form {
            // Use a stacked layout so a long $HOME (e.g. a FileVault
            // user with a deep UNIX home path) doesn't clip on the
            // trailing edge of the settings sheet. Matches Apple's
            // inspector-panel guidance for long filesystem paths.
            //
            // Docs:
            // https://developer.apple.com/documentation/swiftui/labeledcontent
            Section("Data Directory") {
                LabeledContent {
                    EmptyView()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("VM Storage")
                        Text(storagePath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                            .help(storagePath)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    /// disables the protection. `SPOOK_BUNDLE_PROTECTION`
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
                        "SPOOK_BUNDLE_PROTECTION is set — it overrides this setting until unset.",
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
        ProcessInfo.processInfo.environment["SPOOK_BUNDLE_PROTECTION"] != nil
    }

    private func refreshEffective() {
        let (cls, pol) = BundleProtection.recommendedPolicy()
        effectiveClass = cls
        effectivePolicy = pol
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
