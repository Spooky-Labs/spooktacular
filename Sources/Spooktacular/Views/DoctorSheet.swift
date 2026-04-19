import SwiftUI
import SpooktacularKit
@preconcurrency import Virtualization

/// Host-readiness diagnostics sheet — the GUI counterpart of
/// `spook doctor`.
///
/// Runs the same preflight checks the CLI runs: Apple Silicon,
/// macOS version floor, Virtualization.framework availability,
/// host disk space, current VM capacity, and per-Apple-EULA
/// 2-per-host ceiling. Each check reports one of three
/// states — `pass`, `warn`, or `fail` — with a one-line
/// explanation and (for failures) a recovery hint the user can
/// act on directly.
///
/// Opens from the sidebar's "Diagnostics" toolbar button or via
/// the ⌃⌘D keyboard shortcut. The sheet runs all checks on
/// appear and exposes a Re-run button so the operator can retry
/// after fixing an issue (freeing disk space, stopping a VM,
/// etc.) without closing and reopening.
///
/// ## Docs
/// - `ProcessInfo.operatingSystemVersion`:
///   https://developer.apple.com/documentation/foundation/processinfo/operatingsystemversion
/// - `VZVirtualMachine.isSupported`:
///   https://developer.apple.com/documentation/virtualization/vzvirtualmachine/issupported
/// - `URLResourceValues.volumeAvailableCapacity`:
///   https://developer.apple.com/documentation/foundation/urlresourcevalues/volumeavailablecapacity
struct DoctorSheet: View {

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var results: [CheckResult] = []
    @State private var isRunning: Bool = false

    /// Minimum supported host macOS version. Mirrors the CLI's
    /// floor (`Doctor.swift`) and the bundle's `LSMinimumSystemVersion`.
    private static let minMacOS = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

    /// Host disk-space floor below which a clean IPSW install can
    /// fail mid-way. Apple's macOS restore image is ~15 GB; the
    /// sparse disk image for the VM adds overhead.
    private static let minFreeDiskBytes: Int64 = 20 * 1024 * 1024 * 1024  // 20 GB

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultsList
            Divider()
            footer
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480)
        .task { await runChecks() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack {
            Label("Host Diagnostics", systemImage: "stethoscope")
                .font(.headline)
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Re-run") { Task { await runChecks() } }
                    .help("Run the preflight checks again")
            }
        }
        .padding(16)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(results) { result in
                    resultRow(result)
                    if result.id != results.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func resultRow(_ result: CheckResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: result.status.icon)
                .font(.title3)
                .foregroundStyle(result.status.tint)
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.body.weight(.medium))
                Text(result.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let recovery = result.recovery {
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(result.status.accessibilityLabel): \(result.title)")
        .accessibilityValue(result.message)
    }

    private var footer: some View {
        HStack {
            summaryLabel
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .glassButton()
        }
        .padding(16)
    }

    @ViewBuilder
    private var summaryLabel: some View {
        let pass = results.filter { $0.status == .pass }.count
        let warn = results.filter { $0.status == .warn }.count
        let fail = results.filter { $0.status == .fail }.count
        if isRunning {
            Text("Running checks…")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                summaryPill(count: pass, label: "passed", tint: .green)
                if warn > 0 {
                    summaryPill(count: warn, label: "warnings", tint: .yellow)
                }
                if fail > 0 {
                    summaryPill(count: fail, label: "failed", tint: .red)
                }
            }
        }
    }

    private func summaryPill(count: Int, label: String, tint: Color) -> some View {
        Text("\(count) \(label)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
    }

    // MARK: - Checks

    /// Runs every check on a background task to keep the UI
    /// responsive even when a check does I/O (disk capacity).
    /// Results are swapped in atomically so the row list does
    /// not flicker between partial updates.
    @MainActor
    private func runChecks() async {
        isRunning = true
        defer { isRunning = false }

        var next: [CheckResult] = []
        next.append(checkAppleSilicon())
        next.append(checkMacOSVersion())
        next.append(checkVirtualization())
        next.append(await checkDiskSpace())
        next.append(checkVMCapacity())

        // Brief delay so the "Running…" state is perceptible and
        // the Re-run feedback feels responsive, not instant and
        // confusing.
        try? await Task.sleep(for: .milliseconds(250))
        results = next
    }

    // MARK: Architecture

    private func checkAppleSilicon() -> CheckResult {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        if machine.hasPrefix("arm") {
            return CheckResult(
                title: "Apple Silicon",
                message: "Host is \(machine) — compatible.",
                status: .pass
            )
        }
        return CheckResult(
            title: "Apple Silicon",
            message: "Host is \(machine) — not supported.",
            status: .fail,
            recovery: "Spooktacular requires an Apple Silicon Mac (M1 / M2 / M3 / M4 / later). Intel hosts cannot run macOS guests via Apple's Virtualization.framework."
        )
    }

    // MARK: macOS version

    private func checkMacOSVersion() -> CheckResult {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let vString = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        let minString = "\(Self.minMacOS.majorVersion).\(Self.minMacOS.minorVersion)"
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(Self.minMacOS) {
            return CheckResult(
                title: "macOS version",
                message: "macOS \(vString) (minimum \(minString)).",
                status: .pass
            )
        }
        return CheckResult(
            title: "macOS version",
            message: "macOS \(vString) is below the \(minString) minimum.",
            status: .fail,
            recovery: "Update macOS via System Settings → General → Software Update."
        )
    }

    // MARK: Virtualization.framework

    private func checkVirtualization() -> CheckResult {
        if VZVirtualMachine.isSupported {
            return CheckResult(
                title: "Virtualization.framework",
                message: "Available and supported by this host.",
                status: .pass
            )
        }
        return CheckResult(
            title: "Virtualization.framework",
            message: "Not supported by this host.",
            status: .fail,
            recovery: "Confirm the host is Apple Silicon and has not disabled virtualization in a MDM policy."
        )
    }

    // MARK: Disk space

    private func checkDiskSpace() async -> CheckResult {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let freeGB = Double(free) / 1_073_741_824.0
            if free >= Self.minFreeDiskBytes {
                return CheckResult(
                    title: "Disk space",
                    message: String(format: "%.0f GB free on the home volume.", freeGB),
                    status: .pass
                )
            }
            return CheckResult(
                title: "Disk space",
                message: String(format: "Only %.0f GB free — below the 20 GB install floor.", freeGB),
                status: .warn,
                recovery: "Free space under ~/.spooktacular/ipsw/ (cached restore images are the usual culprit) or pass --from-ipsw <local path> when creating a VM to skip the Apple download."
            )
        } catch {
            return CheckResult(
                title: "Disk space",
                message: "Could not read volume capacity: \(error.localizedDescription)",
                status: .warn
            )
        }
    }

    // MARK: VM capacity

    private func checkVMCapacity() -> CheckResult {
        let running = appState.runningVMs.count
        let cap = 2  // Apple macOS EULA
        if running == 0 {
            return CheckResult(
                title: "VM capacity",
                message: "0 of \(cap) VMs running — full capacity available.",
                status: .pass
            )
        }
        if running < cap {
            return CheckResult(
                title: "VM capacity",
                message: "\(running) of \(cap) VMs running.",
                status: .pass
            )
        }
        return CheckResult(
            title: "VM capacity",
            message: "\(cap) of \(cap) VMs running — Apple's macOS EULA ceiling reached.",
            status: .warn,
            recovery: "Stop a workspace before starting another. Two VMs per host is Apple's cap; running more is a EULA violation, not a technical limit."
        )
    }
}

// MARK: - CheckResult

/// One row in the diagnostics sheet. `recovery` is shown beneath
/// the message when non-nil — the CLI's `--json` equivalent field
/// is `"hint"`.
private struct CheckResult: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let status: Status
    var recovery: String?

    enum Status {
        case pass, warn, fail

        var icon: String {
            switch self {
            case .pass: return "checkmark.circle.fill"
            case .warn: return "exclamationmark.triangle.fill"
            case .fail: return "xmark.octagon.fill"
            }
        }

        var tint: Color {
            switch self {
            case .pass: return .green
            case .warn: return .yellow
            case .fail: return .red
            }
        }

        var accessibilityLabel: String {
            switch self {
            case .pass: return "Passed"
            case .warn: return "Warning"
            case .fail: return "Failed"
            }
        }
    }
}
