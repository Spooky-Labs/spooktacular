import SwiftUI
import Charts
import SpooktacularKit

/// Compact Swift Charts panel shown in the workspace inspector.
///
/// Plots two metrics over a rolling 60-second window:
///
/// - **Listening ports** — count reported by the guest agent
/// - **Agent latency** — round-trip health probe in milliseconds
///
/// Both come from the existing ``GuestAgentClient`` so there's no
/// guest-side change required. Metrics are sampled on the host at
/// 5 s (matches the port monitor) and decay off the chart after
/// 60 s of history.
///
/// This is deliberately not a VM-internal CPU/disk graph: those
/// need guest-agent extensions, which are better shipped as a
/// separate release. The host-observable metrics here give an
/// immediately useful "is the workspace healthy" pulse.
@MainActor
@Observable
final class WorkspaceStatsModel {

    struct Sample: Identifiable {
        let id = UUID()
        let at: Date
        let portCount: Int
        let latencyMs: Double?
        /// CPU usage fraction (0…1). `nil` when the agent
        /// doesn't yet support `/api/v1/stats` (older builds) or
        /// when this is the first tick after the agent booted.
        let cpuUsage: Double?
        /// Memory usage fraction (0…1), or `nil` when stats
        /// aren't available.
        let memoryUsage: Double?
    }

    /// Rolling-window samples, oldest first.
    var samples: [Sample] = []

    /// Seconds of history kept on-screen.
    static let window: TimeInterval = 60

    /// Poll interval. Matches ``PortForwardingMonitor`` so the two
    /// surfaces stay in sync.
    static let pollInterval: Duration = .seconds(5)

    private var pollTask: Task<Void, Never>?

    /// Begins polling. Safe to call multiple times.
    func start(client: GuestAgentClient) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(client: client)
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
    }

    /// Stops polling. Samples are retained so returning to the
    /// view while the VM is stopped still shows the last graph.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func tick(client: GuestAgentClient) async {
        let started = Date()
        var latency: Double?
        var portCount: Int = 0
        var cpuUsage: Double?
        var memoryUsage: Double?
        do {
            _ = try await client.health()
            latency = Date().timeIntervalSince(started) * 1000
        } catch {
            latency = nil
        }
        do {
            let ports = try await client.listeningPorts()
            portCount = ports.count
        } catch {
            portCount = 0
        }
        // `stats()` is best-effort — older guest agents don't
        // yet know the `/api/v1/stats` endpoint and will 404.
        // That's a soft failure: we keep charting latency +
        // ports while the CPU / memory lines stay empty.
        do {
            let stats = try await client.stats()
            cpuUsage = stats.cpuUsage
            memoryUsage = stats.memoryUsageFraction
        } catch {
            cpuUsage = nil
            memoryUsage = nil
        }
        let sample = Sample(
            at: Date(),
            portCount: portCount,
            latencyMs: latency,
            cpuUsage: cpuUsage,
            memoryUsage: memoryUsage
        )
        samples.append(sample)
        let cutoff = Date().addingTimeInterval(-Self.window)
        samples.removeAll { $0.at < cutoff }
    }
}

/// SwiftUI surface rendering the ``WorkspaceStatsModel``'s rolling
/// window as two stacked area charts.
struct WorkspaceStatsSidebar: View {

    let model: WorkspaceStatsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Live metrics", systemImage: "waveform.path.ecg")
                .font(.headline)

            cpuChart
            memoryChart
            latencyChart
            portChart
        }
        .padding(16)
        .glassCard(cornerRadius: 16)
    }

    // CPU usage (0-100%) — sourced from `/api/v1/stats` on the
    // guest agent, which computes it as a `host_processor_info`
    // tick delta (same source `top` uses).
    private var cpuChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("CPU")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(model.samples) { sample in
                if let cpu = sample.cpuUsage {
                    AreaMark(
                        x: .value("time", sample.at),
                        y: .value("percent", cpu * 100)
                    )
                    .foregroundStyle(.orange.opacity(0.3))

                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("percent", cpu * 100)
                    )
                    .foregroundStyle(.orange)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 90)
            .chartYAxisLabel("%", position: .leading)
            .chartXAxis(.hidden)
        }
    }

    // Memory usage (active + wired + compressed as a fraction
    // of total installed memory). Cache pages are excluded.
    private var memoryChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Memory")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(model.samples) { sample in
                if let mem = sample.memoryUsage {
                    AreaMark(
                        x: .value("time", sample.at),
                        y: .value("percent", mem * 100)
                    )
                    .foregroundStyle(.purple.opacity(0.3))

                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("percent", mem * 100)
                    )
                    .foregroundStyle(.purple)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 90)
            .chartYAxisLabel("%", position: .leading)
            .chartXAxis(.hidden)
        }
    }

    // MARK: - Charts

    private var latencyChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent round-trip")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(model.samples) { sample in
                if let ms = sample.latencyMs {
                    AreaMark(
                        x: .value("time", sample.at),
                        y: .value("ms", ms)
                    )
                    .foregroundStyle(.blue.opacity(0.3))

                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("ms", ms)
                    )
                    .foregroundStyle(.blue)
                }
            }
            .frame(height: 90)
            .chartYAxisLabel("ms", position: .leading)
            .chartXAxis(.hidden)
        }
    }

    private var portChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Listening ports")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Chart(model.samples) { sample in
                BarMark(
                    x: .value("time", sample.at),
                    y: .value("count", sample.portCount)
                )
                .foregroundStyle(.green.opacity(0.8))
            }
            .frame(height: 70)
            .chartYAxisLabel("#", position: .leading)
            .chartXAxis(.hidden)
        }
    }
}
