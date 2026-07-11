import SwiftUI
import SpooktacularKit

/// Shows the per-VM first-boot provisioning status inline in
/// ``VMDetailView``.
///
/// Driven by ``ProvisioningActivityModel``, which polls the
/// bundle's `provision/` directory every couple of seconds
/// while the detail view is visible. The pane is empty-state-
/// friendly: a fresh VM with no pending script and no previous
/// run shows a single "No first-boot script yet" line.
struct ProvisioningPane: View {

    let bundle: VirtualMachineBundle
    @State private var model = ProvisioningActivityModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if !model.activity.scriptPending && model.activity.lastRun == nil {
                emptyState
            } else {
                if model.activity.scriptPending {
                    pendingSection
                }
                if let run = model.activity.lastRun {
                    lastRunSection(run)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 20)
        .task(id: bundle.id) {
            model.start(bundle: bundle)
        }
        .onDisappear { model.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Provisioning", systemImage: "gearshape.2")
                .font(.headline)

            Spacer()

            if model.activity.scriptPending {
                Text("pending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .glassStatusBadge()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No first-boot script yet.")
                .foregroundStyle(.secondary)
            Text("Templates and custom user-data scripts land here as `first-boot.sh`. The Guest Tools provisioner runs it once on next boot and logs the result back to this pane.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Pending

    private var pendingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pending")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundStyle(.orange)
                Text("first-boot.sh")
                    .font(.body.monospaced())
                Spacer()
                if let since = model.activity.scriptPendingSince {
                    Text(since, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Last run

    private func lastRunSection(
        _ run: ProvisioningActivity.Run
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last run")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if run.stdoutBytes > 0 {
                        logLine(
                            label: "stdout",
                            bytes: run.stdoutBytes,
                            url: bundle.provisionStdoutURL
                        )
                    }
                    if run.stderrBytes > 0 {
                        logLine(
                            label: "stderr",
                            bytes: run.stderrBytes,
                            url: bundle.provisionStderrURL
                        )
                    }
                    if run.stdoutBytes == 0 && run.stderrBytes == 0 {
                        Text("No output captured.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    logLine(
                        label: "script",
                        bytes: nil,
                        url: bundle.provisionRanScriptURL
                    )
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: run.succeeded
                        ? "checkmark.circle.fill"
                        : "xmark.octagon.fill")
                        .foregroundStyle(run.succeeded ? .green : .red)
                    Text(run.succeeded ? "Completed" : "Failed")
                        .font(.body)
                    if !run.succeeded {
                        Text("exit \(run.exitCode)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text(run.completedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func logLine(
        label: String,
        bytes: Int?,
        url: URL
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let bytes {
                Text("\(bytes) B")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open", systemImage: "arrow.up.right.square")
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open \(label) in the default editor")
        }
    }
}

// MARK: - Activity model

/// Polls a VM bundle's `provision/` directory for changes and
/// publishes a ``ProvisioningActivity`` snapshot. Lives as
/// long as the owning view; auto-stops when the view goes
/// away.
///
/// Polling (vs. FSEvents) because the cadence is slow (~2 Hz),
/// the directory is small, and the bundle URL can change when
/// the user navigates between VMs — simpler to tear down than
/// an FSEvents stream.
@MainActor
@Observable
final class ProvisioningActivityModel {

    /// The current snapshot. Replaced wholesale on every poll;
    /// SwiftUI diffing handles pending / last-run changes
    /// efficiently.
    var activity = ProvisioningActivity(scriptPending: false)

    private var pollTask: Task<Void, Never>?

    /// Starts polling for the given bundle. If another bundle
    /// was being polled, that session is cancelled first — the
    /// model is "last writer wins" for the active bundle.
    func start(bundle: VirtualMachineBundle) {
        stop()
        refresh(bundle: bundle)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                self?.refresh(bundle: bundle)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func refresh(bundle: VirtualMachineBundle) {
        let next = bundle.readProvisioningActivity()
        if next != activity {
            activity = next
        }
    }
}
