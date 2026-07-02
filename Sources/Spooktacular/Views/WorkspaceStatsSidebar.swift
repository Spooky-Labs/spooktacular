import SwiftUI
import Charts
import SpooktacularKit

/// Compact Swift Charts panel shown in the workspace inspector.
///
/// Plots metrics over a rolling 60-second window: CPU usage,
/// memory usage, disk I/O, energy, and paging — all guest- or
/// host-sampled fractions/rates.
///
/// CPU / memory / load / process count arrive as server-pushed
/// NDJSON frames on a single vsock connection to
/// `/api/v1/stats/stream`. The host never polls them — the guest
/// owns the cadence and pushes one frame per second as long as
/// the workspace view stays on screen. This keeps the UI
/// responsive under contention and matches how production
/// observability agents (Prometheus `stream` exporters, eBPF
/// tracers) expose time-series to their consumers.
@MainActor
@Observable
final class WorkspaceStatsModel {

    struct Sample: Identifiable {
        let id = UUID()
        let at: Date
        /// CPU usage fraction (0…1). `nil` on the first frame
        /// after the agent boots (delta needs two observations).
        let cpuUsage: Double?
        /// Memory usage fraction (0…1).
        let memoryUsage: Double?
        /// Disk-read rate in MiB/s since the previous sample.
        /// `nil` until the second frame (delta needs two
        /// observations) or when the source doesn't provide
        /// cumulative disk counters.
        let diskReadRateMiBPerSec: Double?
        /// Disk-write rate in MiB/s since the previous sample.
        let diskWriteRateMiBPerSec: Double?
        /// Power draw in watts — `ri_billed_energy` is
        /// nanojoules cumulative, so the rate per second is
        /// the process's instantaneous wattage.
        let powerWatts: Double?
        /// Page-ins per second — a spike here is a host-side
        /// signal that the guest is swapping / memory-
        /// pressured.
        let pageInRatePerSec: Double?
    }

    /// Rolling-window samples, oldest first.
    var samples: [Sample] = []

    /// Previous frame's cumulative counters, used to derive
    /// per-second rates for disk I/O / energy / page-ins.
    /// Rates are more useful than raw cumulative bytes for a
    /// 60-second chart — "is the VM reading the disk RIGHT
    /// NOW" beats "cumulative since boot" every time.
    private var prevAt: Date?
    private var prevDiskBytesRead: UInt64?
    private var prevDiskBytesWritten: UInt64?
    private var prevEnergyNanoJoules: UInt64?
    private var prevPageIns: UInt64?

    /// Seconds of history kept on-screen.
    static let window: TimeInterval = 60

    private var streamTask: Task<Void, Never>?

    /// Subscribes to the guest's push stream. Safe to call
    /// multiple times — previous tasks are cancelled first.
    ///
    /// - Parameter listener: The Apple-native ``AgentEventListener``
    ///   for this VM. The guest agent dials into it on boot and
    ///   pushes length-prefixed ``GuestEvent`` frames — this is
    ///   the sole source of `.stats` samples.
    func start(listener: AgentEventListener) {
        streamTask?.cancel()

        streamTask = Task { [weak self] in
            do {
                for try await event in listener.events() {
                    guard !Task.isCancelled else { return }
                    guard case .stats(let stats) = event else { continue }
                    self?.appendFrame(stats: stats)
                }
            } catch {
                // Stream ended (VM stopped, connection dropped,
                // agent not running). Existing samples stay
                // on-screen so the graph doesn't flash empty.
            }
        }
    }

    /// Stops the stream. Samples are retained so the chart still
    /// renders the last window while the VM is stopped.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func appendFrame(stats: GuestStatsResponse) {
        let now = Date()

        // Derive per-second rates from consecutive cumulative
        // counters. Rates are `nil` on the first frame (no
        // baseline) or whenever the source leaves the field
        // unset — preserving "no data" for the chart's
        // `if let` guards instead of drawing a misleading 0.
        let dt = prevAt.map { now.timeIntervalSince($0) } ?? 0
        let diskReadRate = rate(
            current: stats.diskBytesRead,
            previous: prevDiskBytesRead,
            seconds: dt
        ).map { $0 / (1024.0 * 1024.0) }
        let diskWriteRate = rate(
            current: stats.diskBytesWritten,
            previous: prevDiskBytesWritten,
            seconds: dt
        ).map { $0 / (1024.0 * 1024.0) }
        let powerWatts = rate(
            current: stats.energyNanoJoules,
            previous: prevEnergyNanoJoules,
            seconds: dt
        ).map { $0 / 1_000_000_000.0 }  // nJ/s = J/s = W
        let pageInRate = rate(
            current: stats.pageIns,
            previous: prevPageIns,
            seconds: dt
        )

        let sample = Sample(
            at: now,
            cpuUsage: stats.cpuUsage,
            memoryUsage: stats.memoryUsageFraction,
            diskReadRateMiBPerSec: diskReadRate,
            diskWriteRateMiBPerSec: diskWriteRate,
            powerWatts: powerWatts,
            pageInRatePerSec: pageInRate
        )
        samples.append(sample)

        prevAt = now
        prevDiskBytesRead = stats.diskBytesRead
        prevDiskBytesWritten = stats.diskBytesWritten
        prevEnergyNanoJoules = stats.energyNanoJoules
        prevPageIns = stats.pageIns

        let cutoff = now.addingTimeInterval(-Self.window)
        samples.removeAll { $0.at < cutoff }
    }

    /// Shared helper for turning two cumulative counters +
    /// an elapsed interval into a rate per second, preserving
    /// `nil` when either end of the delta is missing.
    private func rate(current: UInt64?, previous: UInt64?, seconds: TimeInterval) -> Double? {
        guard let current, let previous, seconds > 0 else { return nil }
        // `current < previous` only happens if the backing
        // process restarted (XPC-worker crash-restart) or the
        // counter wrapped — either way, the right answer is
        // "no data this sample" rather than a negative rate.
        guard current >= previous else { return nil }
        return Double(current - previous) / seconds
    }
}

/// SwiftUI surface rendering the ``WorkspaceStatsModel``'s rolling
/// window as two stacked area charts.
struct WorkspaceStatsSidebar: View {

    let model: WorkspaceStatsModel

    var body: some View {
        // `GlassEffectContainer` batches the outer card + the
        // four per-chart surfaces into one render pass and lets
        // them morph smoothly as samples stream in. Apple's
        // guidance: use a container whenever multiple glass
        // surfaces cluster within a common ancestor — avoids
        // the "every-chart-has-its-own-pane" stacked-glass look
        // and keeps the GPU from rebuilding overlapping blurs.
        // One glass card per metric; the outer container keeps
        // the whole panel on one rendering pass per Apple's
        // "Applying Liquid Glass to custom views" guidance
        // (<https://developer.apple.com/documentation/swiftui/
        // applying-liquid-glass-to-custom-views>), and the
        // spacing here is larger than the inner VStack's so
        // individual cards stay distinct rather than blending.
        GlassEffectContainer(spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Label("Live metrics", systemImage: "waveform.path.ecg")
                    .font(.headline)
                    .padding(.leading, 4)

                cpuChart
                memoryChart
                diskChart
                powerChart
                pageInChart
            }
        }
    }

    // MARK: - Chart components

    /// One Liquid-Glass card per metric. Layout top-to-bottom:
    ///
    /// 1. Header row — SF Symbol + title on the left, current
    ///    value readout on the right. The icon gives the card
    ///    a quick semantic tag; the readout confirms the pipe
    ///    is live even when the chart line hugs the X-axis.
    /// 2. Chart — the caller's plot; kept compact at 90pt tall
    ///    so a long description below still fits without
    ///    pushing the next card off-screen.
    /// 3. Description — the full "what / axes / how to read /
    ///    where from" paragraph, rendered below the chart so
    ///    it sits under the data it's explaining (Apple's
    ///    System Settings pattern — the copy is the footer,
    ///    not a floating tooltip).
    ///
    /// The whole stack sits on a `.regular.interactive()`
    /// glass surface so hover / press feedback matches the
    /// rest of the app's Liquid Glass controls.
    private func metricCard<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        value: String?,
        description: String,
        @ViewBuilder chart: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                } icon: {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .imageScale(.medium)
                }
                Spacer(minLength: 8)
                Text(value ?? "—")
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(value == nil ? .tertiary : .primary)
            }

            chart()

            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 14)
    }

    /// Formats a `Double?` as a short readable string.
    /// Returns `nil` (which the header renders as "—") when
    /// the source is truly missing — as opposed to 0.0 which
    /// is a real value and renders like "0.0%".
    private func readout(_ value: Double?, unit: String, digits: Int = 1) -> String? {
        guard let value else { return nil }
        return String(format: "%.\(digits)f %@", value, unit)
    }

    // MARK: - Charts

    private var cpuChart: some View {
        metricCard(
            title: "CPU",
            systemImage: "cpu",
            tint: .blue,
            value: readout(model.samples.last?.cpuUsage.map { $0 * 100 }, unit: "%"),
            description: "How much of this virtual machine's processing power is in use. The horizontal axis is the last 60 seconds; the vertical axis is the percent of allocated virtual CPUs currently busy. Zero means the guest is idle; 100% means every virtual CPU you've allocated is fully saturated. Brief spikes are normal — they happen when the guest launches an app or renders a page. A line that stays at 100% for minutes means the guest is compute-bound and could use more vCPUs. The measurement comes from ps(1), which reports the CPU time accumulated by the VM's backing process the same way Activity Monitor does."
        ) {
            Chart(model.samples) { sample in
                if let cpu = sample.cpuUsage {
                    AreaMark(
                        x: .value("time", sample.at),
                        y: .value("percent", cpu * 100)
                    )
                    .foregroundStyle(.blue.opacity(0.3))

                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("percent", cpu * 100)
                    )
                    .foregroundStyle(.blue)
                }
            }
            .chartYScale(domain: 0...100)
            .frame(height: 90)
            .chartYAxisLabel("%", position: .leading)
            .chartXAxis(.hidden)
        }
    }

    private var memoryChart: some View {
        metricCard(
            title: "Memory",
            systemImage: "memorychip",
            tint: .purple,
            value: readout(model.samples.last?.memoryUsage.map { $0 * 100 }, unit: "%"),
            description: "The share of this virtual machine's memory that's actively held in your Mac's RAM right now. The horizontal axis is the last 60 seconds; the vertical axis is the percent of allocated memory in active use. A rising value means the guest is doing more; a falling value means macOS is compressing pages the guest hasn't touched recently, which frees up real RAM for your Mac. Don't worry if it settles at a moderate number — that's normal caching behavior. Sourced from the VM backing process's resident memory footprint as reported by the macOS kernel."
        ) {
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

    private var diskChart: some View {
        // Sum read + write for the header readout so a single
        // number represents "overall disk activity"; the chart
        // itself keeps them split.
        let last = model.samples.last
        let total: Double? = {
            switch (last?.diskReadRateMiBPerSec, last?.diskWriteRateMiBPerSec) {
            case (nil, nil): return nil
            case (let r, let w): return (r ?? 0) + (w ?? 0)
            }
        }()
        return metricCard(
            title: "Disk Activity",
            systemImage: "internaldrive",
            tint: .teal,
            value: readout(total, unit: "MiB/s"),
            description: "How fast the virtual machine is reading from and writing to its disk. The horizontal axis is the last 60 seconds; the vertical axis is megabytes per second. The teal line tracks reads (loading apps, opening files); the pink line tracks writes (saving work, updates). Short spikes are normal app-launch or boot activity; a steady high read rate suggests the guest is streaming a large file, while a steady high write rate often means a system update or build is running. The measurement comes from your Mac's kernel accounting for every block operation the guest's virtual disk performs."
        ) {
            Chart(model.samples) { sample in
                if let read = sample.diskReadRateMiBPerSec {
                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("MiB/s", read),
                        series: .value("direction", "read")
                    )
                    .foregroundStyle(.teal)
                }
                if let write = sample.diskWriteRateMiBPerSec {
                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("MiB/s", write),
                        series: .value("direction", "write")
                    )
                    .foregroundStyle(.pink)
                }
            }
            .frame(height: 90)
            .chartYAxisLabel("MiB/s", position: .leading)
            .chartXAxis(.hidden)
            .chartForegroundStyleScale([
                "read": .teal, "write": .pink,
            ])
            .chartLegend(position: .bottom, alignment: .leading, spacing: 4)
        }
    }

    private var powerChart: some View {
        metricCard(
            title: "Energy",
            systemImage: "bolt",
            tint: .green,
            value: readout(model.samples.last?.powerWatts, unit: "W", digits: 2),
            description: "How much power the virtual machine is drawing from your Mac. The horizontal axis is the last 60 seconds; the vertical axis is watts. A fraction of a watt is typical for an idle guest; a sustained couple of watts usually means the guest is compiling, transcoding, or running something compute-heavy. Lower numbers mean longer battery life when you're unplugged. Sourced from the same power-accounting counters that Apple's powermetrics command-line tool reports."
        ) {
            Chart(model.samples) { sample in
                if let w = sample.powerWatts {
                    AreaMark(
                        x: .value("time", sample.at),
                        y: .value("W", w)
                    )
                    .foregroundStyle(.green.opacity(0.3))

                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("W", w)
                    )
                    .foregroundStyle(.green)
                }
            }
            .frame(height: 90)
            .chartYAxisLabel("W", position: .leading)
            .chartXAxis(.hidden)
        }
    }

    private var pageInChart: some View {
        metricCard(
            title: "Paging",
            systemImage: "arrow.up.arrow.down.circle",
            tint: .indigo,
            value: readout(model.samples.last?.pageInRatePerSec, unit: "/s", digits: 0),
            description: "How often pages of the virtual machine's memory are being re-read from storage because macOS compressed them out of active RAM. The horizontal axis is the last 60 seconds; the vertical axis is page-ins per second. Zero is the healthy resting value — a flat line at the bottom means your Mac has plenty of room and isn't swapping the VM. Sustained non-zero activity suggests the VM could use more allocated RAM, or the Mac is under memory pressure overall. Reported by your Mac's kernel via ri_pageins on the VM's backing process."
        ) {
            Chart(model.samples) { sample in
                if let rate = sample.pageInRatePerSec {
                    AreaMark(
                        x: .value("time", sample.at),
                        y: .value("pages/s", rate)
                    )
                    .foregroundStyle(.indigo.opacity(0.3))

                    LineMark(
                        x: .value("time", sample.at),
                        y: .value("pages/s", rate)
                    )
                    .foregroundStyle(.indigo)
                }
            }
            .chartYScale(domain: 0...max(10, (model.samples.compactMap { $0.pageInRatePerSec }.max() ?? 0)))
            .frame(height: 90)
            .chartYAxisLabel("p/s", position: .leading)
            .chartXAxis(.hidden)
        }
    }

}
