import SwiftUI
import SpooktacularKit
@preconcurrency import Virtualization

/// Host-readiness diagnostics sheet — the GUI counterpart of
/// `spook doctor`.
///
/// Runs the same preflight checks the CLI runs: Apple Silicon,
/// macOS version floor, Virtualization.framework availability,
/// host disk space, current VM capacity, and per-Apple-EULA
/// 2-per-host ceiling. Each check reports one of five states —
/// `pending`, `running`, `passed`, `warning`, `failed` — so the
/// user sees progress in real time rather than a single all-at-once
/// reveal.
///
/// ## Design
///
/// - **Glass rows**: each check is a `.glassCard`-wrapped row so
///   the sheet reads as a vertical stack of material pills on
///   macOS 26+ (Liquid Glass) and as material cards with
///   vibrancy on macOS 14–15.
/// - **Glowing indicators**: the status icon carries a radial
///   shadow in its tint color plus a one-shot `.symbolEffect(.pulse)`
///   on state transition so the eye catches the change.
/// - **Progress**: the indeterminate `ProgressView` beside the
///   currently-running check is paired with a determinate linear
///   progress bar under the header showing overall completion.
/// - Each check runs sequentially on the main actor so
///   UI updates coalesce cleanly in the run order.
///
/// ## Docs
/// - `ProcessInfo.operatingSystemVersion`:
///   https://developer.apple.com/documentation/foundation/processinfo/operatingsystemversion
/// - `VZVirtualMachine.isSupported`:
///   https://developer.apple.com/documentation/virtualization/vzvirtualmachine/issupported
/// - `URLResourceValues.volumeAvailableCapacity`:
///   https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacity
/// - `Image.symbolEffect(_:options:value:)`:
///   https://developer.apple.com/documentation/swiftui/image/symboleffect(_:options:value:)
struct DoctorSheet: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var items: [CheckItem] = Self.initialItems()
    @State private var isRunning: Bool = false

    /// Minimum supported host macOS version. Mirrors the CLI's
    /// floor and the bundle's `LSMinimumSystemVersion`.
    private static let minMacOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    /// Disk-space floor below which a clean IPSW install can
    /// fail mid-way. Apple's macOS restore image is ~15 GB; the
    /// sparse disk image adds overhead.
    private static let minFreeDiskBytes: Int64 = 20 * 1024 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            header
            progressBar
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520)
        .task { await runChecks() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Label("Host Diagnostics", systemImage: "stethoscope")
                .font(.headline)
            Spacer()
            Button {
                Task { await runChecks() }
            } label: {
                Label("Re-run", systemImage: "arrow.clockwise")
                    .labelStyle(.titleOnly)
            }
            .glassButton()
            .controlSize(.regular)
            .disabled(isRunning)
            .help("Run the preflight checks again")
        }
        .padding(16)
    }

    /// Linear progress bar under the header showing the fraction
    /// of checks that have finalized (i.e., left the `.pending` /
    /// `.running` states). Hidden while idle to avoid pulling
    /// the eye during a stable state.
    @ViewBuilder
    private var progressBar: some View {
        let total = Double(items.count)
        let done = Double(items.filter(\.state.isFinal).count)
        let fraction = total > 0 ? done / total : 0
        if isRunning {
            ProgressView(value: fraction, total: 1)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .accessibilityLabel("Overall progress")
                .accessibilityValue("\(Int(fraction * 100)) percent complete")
        }
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    CheckRow(item: item)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(16)
            .animation(.smooth(duration: 0.25), value: items.map(\.state))
        }
    }

    private var footer: some View {
        HStack {
            summaryLabel
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .glassProminentButton()
        }
        .padding(16)
    }

    @ViewBuilder
    private var summaryLabel: some View {
        let passed = items.filter { $0.state == .passed }.count
        let warned = items.filter { $0.state == .warning }.count
        let failed = items.filter { $0.state == .failed }.count
        if isRunning {
            Text("Running checks…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                countPill(count: passed, label: "passed", tint: .green)
                if warned > 0 {
                    countPill(count: warned, label: "warnings", tint: .yellow)
                }
                if failed > 0 {
                    countPill(count: failed, label: "failed", tint: .red)
                }
            }
        }
    }

    private func countPill(count: Int, label: String, tint: Color) -> some View {
        Text("\(count) \(label)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
    }

    // MARK: - Runner

    /// Runs every check sequentially on the main actor, updating
    /// the relevant `items[i].state` entry before and after each
    /// check so the UI can reflect `.running` → terminal state
    /// transitions with animation.
    ///
    /// A brief `Task.sleep` between reset and the first check
    /// gives SwiftUI a frame to animate the `.running` state into
    /// view — otherwise very-fast checks (Apple Silicon probe is
    /// essentially free) would skip the `.running` visual.
    @MainActor
    private func runChecks() async {
        isRunning = true
        defer { isRunning = false }

        // Reset every row to `.pending` so the UI shows an empty
        // field before the run cascades through.
        items = Self.initialItems()

        // Tiny delay so the user sees the reset → running
        // animation rather than a flash of final state.
        try? await Task.sleep(for: .milliseconds(120))

        for idx in items.indices {
            items[idx].state = .running
            try? await Task.sleep(for: .milliseconds(220))
            let outcome = await Self.probes[idx].run(appState)
            items[idx].state = outcome.state
            items[idx].message = outcome.message
            items[idx].recovery = outcome.recovery
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    // MARK: - Probe registry

    /// Static probe list keyed by index so the runner can update
    /// `items[i]` in lock-step. Keeping the shape static makes
    /// the runner's loop allocation-free per invocation.
    private static let probes: [Probe] = [
        Probe(title: "Apple Silicon") { _ in checkAppleSilicon() },
        Probe(title: "macOS version") { _ in checkMacOSVersion() },
        Probe(title: "Virtualization.framework") { _ in checkVirtualization() },
        Probe(title: "Disk space") { _ in await checkDiskSpace() },
        Probe(title: "VM capacity") { state in checkVMCapacity(appState: state) }
    ]

    private static func initialItems() -> [CheckItem] {
        probes.map { CheckItem(title: $0.title) }
    }

    // MARK: - Individual checks

    private static func checkAppleSilicon() -> Outcome {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        if machine.hasPrefix("arm") {
            return Outcome(state: .passed, message: "Host is \(machine) — compatible.")
        }
        return Outcome(
            state: .failed,
            message: "Host is \(machine) — not supported.",
            recovery: "Spooktacular requires an Apple Silicon Mac (M1 / M2 / M3 / M4 / later)."
        )
    }

    private static func checkMacOSVersion() -> Outcome {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let vString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        let minString = "\(Self.minMacOS.majorVersion).\(Self.minMacOS.minorVersion)"
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minMacOS) {
            return Outcome(state: .passed, message: "macOS \(vString) (minimum \(minString)).")
        }
        return Outcome(
            state: .failed,
            message: "macOS \(vString) is below the \(minString) minimum.",
            recovery: "Update macOS via System Settings → General → Software Update."
        )
    }

    private static func checkVirtualization() -> Outcome {
        if VZVirtualMachine.isSupported {
            return Outcome(state: .passed, message: "Available and supported by this host.")
        }
        return Outcome(
            state: .failed,
            message: "Not supported by this host.",
            recovery: "Confirm the host is Apple Silicon and virtualization isn't disabled by an MDM policy."
        )
    }

    private static func checkDiskSpace() async -> Outcome {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let freeGB = Double(free) / 1_073_741_824.0
            if free >= Self.minFreeDiskBytes {
                return Outcome(state: .passed, message: String(format: "%.0f GB free on the home volume.", freeGB))
            }
            return Outcome(
                state: .warning,
                message: String(format: "Only %.0f GB free — below the 20 GB install floor.", freeGB),
                recovery: "Free space under ~/.spooktacular/ipsw/ or pass --from-ipsw <local path> when creating a VM."
            )
        } catch {
            return Outcome(
                state: .warning,
                message: "Could not read volume capacity: \(error.localizedDescription)"
            )
        }
    }

    @MainActor
    private static func checkVMCapacity(appState: AppState) -> Outcome {
        let running = appState.runningVMs.count
        let cap = 2
        if running == 0 {
            return Outcome(state: .passed, message: "0 of \(cap) VMs running — full capacity available.")
        }
        if running < cap {
            return Outcome(state: .passed, message: "\(running) of \(cap) VMs running.")
        }
        return Outcome(
            state: .warning,
            message: "\(cap) of \(cap) VMs running — Apple's macOS EULA ceiling reached.",
            recovery: "Stop a workspace before starting another. Two VMs per host is Apple's cap."
        )
    }
}

// MARK: - Row view

/// One diagnostic row. Renders on a `.glassCard` background so
/// the sheet looks like a stack of Liquid Glass pills on
/// macOS 26+, falling back to an `.ultraThinMaterial` card on
/// earlier releases.
private struct CheckRow: View {
    let item: CheckItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            indicator
                .frame(width: 28, height: 28, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.medium))
                if !item.message.isEmpty {
                    Text(item.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let recovery = item.recovery {
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.state.accessibilityLabel): \(item.title)")
        .accessibilityValue(item.message)
    }

    /// State-specific indicator. `.pending` is a dotted circle,
    /// `.running` is an indeterminate progress spinner, and the
    /// terminal states render a symbol with a radial glow shadow
    /// plus a one-shot `.symbolEffect(.pulse)` on the value
    /// transition so the change is visible at a glance.
    @ViewBuilder
    private var indicator: some View {
        switch item.state {
        case .pending:
            Image(systemName: "circle.dotted")
                .font(.title3)
                .foregroundStyle(.secondary)

        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(.accentColor)

        case .passed, .warning, .failed:
            Image(systemName: item.state.icon)
                .font(.title3)
                .foregroundStyle(item.state.tint)
                .shadow(color: item.state.tint.opacity(0.55), radius: 10)
                .shadow(color: item.state.tint.opacity(0.35), radius: 4)
                .symbolEffect(.pulse, options: .nonRepeating, value: item.state)
        }
    }
}

// MARK: - Data model

private struct CheckItem: Identifiable, Equatable {
    let id = UUID()
    let title: String
    var state: State = .pending
    var message: String = ""
    var recovery: String?

    enum State: Equatable {
        case pending
        case running
        case passed
        case warning
        case failed

        var isFinal: Bool {
            switch self {
            case .passed, .warning, .failed: return true
            default: return false
            }
        }

        var icon: String {
            switch self {
            case .pending: return "circle.dotted"
            case .running: return "progress.indicator"
            case .passed: return "checkmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .pending: return .secondary
            case .running: return .accentColor
            case .passed: return .green
            case .warning: return .yellow
            case .failed: return .red
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .pending: return "Pending"
            case .running: return "Running"
            case .passed: return "Passed"
            case .warning: return "Warning"
            case .failed: return "Failed"
            }
        }
    }
}

private struct Probe {
    let title: String
    let run: @MainActor (AppState) async -> Outcome

    init(title: String, run: @escaping @MainActor (AppState) async -> Outcome) {
        self.title = title
        self.run = run
    }
}

private struct Outcome {
    let state: CheckItem.State
    let message: String
    var recovery: String?
}
