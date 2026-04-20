import SwiftUI
import Charts
import SpooktacularKit

/// Compact Swift Charts panel shown in the workspace inspector.
///
/// Plots four metrics over a rolling 60-second window:
///
/// - **CPU usage** — guest-side fraction, pushed by the agent
/// - **Memory usage** — guest-side fraction, pushed by the agent
/// - **Agent latency** — host-observed round-trip in milliseconds
/// - **Listening ports** — count reported by the guest agent
///
/// CPU / memory / load / process count arrive as server-pushed
/// NDJSON frames on a single vsock connection to
/// `/api/v1/stats/stream`. The host never polls them — the guest
/// owns the cadence and pushes one frame per second as long as
/// the workspace view stays on screen. This keeps the UI
/// responsive under contention and matches how production
/// observability agents (Prometheus `stream` exporters, eBPF
/// tracers) expose time-series to their consumers.
///
/// Latency and listening ports remain host-polled because they're
/// host-measurable (round-trip clock, Bonjour-style port probe)
/// and don't benefit from pushing. The two loops are merged by
/// the stream frame arrival event — a fresh stats frame triggers
/// a combined sample with the latest measured latency/ports.
@MainActor
@Observable
final class WorkspaceStatsModel {

    struct Sample: Identifiable {
        let id = UUID()
        let at: Date
        let portCount: Int
        let latencyMs: Double?
        /// CPU usage fraction (0…1). `nil` on the first frame
        /// after the agent boots (delta needs two observations).
        let cpuUsage: Double?
        /// Memory usage fraction (0…1).
        let memoryUsage: Double?
    }

    /// Rolling-window samples, oldest first.
    var samples: [Sample] = []

    /// Seconds of history kept on-screen.
    static let window: TimeInterval = 60

    /// How often the host-side probes (latency + ports) refresh
    /// between stream frames.
    static let hostProbeInterval: Duration = .seconds(5)

    private var streamTask: Task<Void, Never>?
    private var hostProbeTask: Task<Void, Never>?

    /// Latest host-side probes, refreshed independently of the
    /// stream. Each new stats frame combines them into the
    /// rolling sample buffer.
    private var lastLatencyMs: Double?
    private var lastPortCount: Int = 0

    /// Subscribes to the guest's push stream. Safe to call
    /// multiple times — previous tasks are cancelled first.
    ///
    /// - Parameters:
    ///   - listener: The Apple-native ``AgentEventListener`` for
    ///     this VM. The guest agent dials into it on boot and
    ///     pushes length-prefixed ``GuestEvent`` frames — this
    ///     is the sole source of `.stats` samples.
    ///   - client: Host-side RPC client used for latency and
    ///     port-count probes. These measurements are host-
    ///     observable so they don't belong on the push stream.
    func start(listener: AgentEventListener, client: GuestAgentClient) {
        streamTask?.cancel()
        hostProbeTask?.cancel()

        hostProbeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeHostMetrics(client: client)
                try? await Task.sleep(for: Self.hostProbeInterval)
            }
        }

        streamTask = Task { [weak self] in
            do {
                for try await event in listener.events() {
                    guard !Task.isCancelled else { return }
                    guard case .stats(let stats) = event else { continue }
                    await self?.appendFrame(stats: stats)
                }
            } catch {
                // Stream ended (VM stopped, connection dropped,
                // agent not running). Existing samples stay
                // on-screen so the graph doesn't flash empty.
            }
        }
    }

    /// Stops the stream and host probe. Samples are retained so
    /// the chart still renders the last window while the VM is
    /// stopped.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        hostProbeTask?.cancel()
        hostProbeTask = nil
    }

    private func appendFrame(stats: GuestStatsResponse) {
        let sample = Sample(
            at: Date(),
            portCount: lastPortCount,
            latencyMs: lastLatencyMs,
            cpuUsage: stats.cpuUsage,
            memoryUsage: stats.memoryUsageFraction
        )
        samples.append(sample)
        let cutoff = Date().addingTimeInterval(-Self.window)
        samples.removeAll { $0.at < cutoff }
    }

    private func probeHostMetrics(client: GuestAgentClient) async {
        let started = Date()
        do {
            _ = try await client.health()
            lastLatencyMs = Date().timeIntervalSince(started) * 1000
        } catch {
            lastLatencyMs = nil
        }
        do {
            lastPortCount = try await client.listeningPorts().count
        } catch {
            lastPortCount = 0
        }
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
