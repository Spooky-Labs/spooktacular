import Foundation
import SpookCore

// MARK: - Metrics Collector

/// Thread-safe metrics collector for Spooktacular host operations.
///
/// `MetricsCollector` is a singleton actor that accumulates operational
/// counters, gauges, and simplified summaries for all host-level events
/// (VM clones, starts, stops, API requests, etc.) and exposes them in
/// [Prometheus text exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/).
///
/// No external dependencies are required -- the actor generates the
/// `text/plain; version=0.0.4` output directly.
///
/// ## Usage
///
/// Record events from anywhere in the codebase:
///
/// ```swift
/// await MetricsCollector.shared.recordClone(durationSeconds: 1.23)
/// await MetricsCollector.shared.updateVMCount(3)
/// ```
///
/// Expose the `/metrics` endpoint from the HTTP API server:
///
/// ```swift
/// let text = await MetricsCollector.shared.prometheusText()
/// ```
///
/// ## Thread Safety
///
/// All mutable state is isolated to the actor, so callers may record
/// metrics from any task or dispatch queue without additional
/// synchronization.
public actor MetricsCollector {

    /// The shared singleton instance.
    public static let shared = MetricsCollector()

    // MARK: - Signpost Provider

    /// The signpost provider used to emit lifecycle tracing intervals.
    private let signpost: any SignpostProvider

    // MARK: - Gauges (current values)

    /// The number of VMs currently running.
    private var runningVMs: Int = 0

    /// The maximum number of concurrent VMs allowed (kernel limit).
    private var maxVMs: Int = 2

    /// Free disk space on the host volume, in gigabytes.
    private var freeDiskGB: Double = 0

    // MARK: - Counters (monotonically increasing)

    /// Total number of VM clone operations performed.
    private var clonesTotal: Int = 0

    /// Total number of VM start operations performed.
    private var startsTotal: Int = 0

    /// Total number of VM stop operations performed.
    private var stopsTotal: Int = 0

    /// Total number of VM delete operations performed.
    private var deletesTotal: Int = 0

    /// Total API requests, keyed by `"METHOD /path"`.
    private var apiRequestsTotal: [String: Int] = [:]

    /// Total number of API errors returned.
    private var apiErrorsTotal: Int = 0

    // MARK: - Summaries (simplified: count + sum)

    /// Recorded durations for clone operations, in seconds.
    private var cloneLatencySeconds: [Double] = []

    /// Recorded durations for boot (start) operations, in seconds.
    private var bootLatencySeconds: [Double] = []

    /// Recorded durations for SSH-ready checks, in seconds.
    private var sshReadyLatencySeconds: [Double] = []

    // MARK: - Runner Lifecycle Summaries

    /// Recorded durations from boot to runner registration, in seconds.
    private var runnerRegistrationLatencySeconds: [Double] = []

    /// Recorded durations from runner ready to first job started, in seconds.
    private var timeToFirstJobSeconds: [Double] = []

    /// Recorded durations for scrub/recycle operations, in seconds.
    private var scrubLatencySeconds: [Double] = []

    /// Total number of cleanup failures observed.
    private var cleanupFailuresTotal: Int = 0

    // MARK: - Initializer

    /// Creates a metrics collector with the given signpost provider.
    ///
    /// - Parameter signpost: The provider used to emit lifecycle tracing
    ///   intervals. Defaults to ``SilentSignpostProvider`` which discards
    ///   all signpost data.
    public init(signpost: any SignpostProvider = SilentSignpostProvider()) {
        self.signpost = signpost
    }

    // MARK: - Recording Events

    /// Records a completed VM clone operation.
    ///
    /// - Parameter durationSeconds: Wall-clock duration of the clone, in seconds.
    public func recordClone(durationSeconds: Double) {
        clonesTotal += 1
        cloneLatencySeconds.append(durationSeconds)
        let id = signpost.beginInterval("clone")
        signpost.endInterval("clone", id: id)
    }

    /// Records a completed VM start operation.
    ///
    /// - Parameter durationSeconds: Wall-clock duration from start request
    ///   to the VM reporting as running, in seconds.
    public func recordStart(durationSeconds: Double) {
        startsTotal += 1
        bootLatencySeconds.append(durationSeconds)
        let id = signpost.beginInterval("boot")
        signpost.endInterval("boot", id: id)
    }

    /// Records a completed VM stop operation.
    public func recordStop() {
        stopsTotal += 1
    }

    /// Records a completed VM delete operation.
    public func recordDelete() {
        deletesTotal += 1
    }

    /// Records an incoming API request.
    ///
    /// - Parameters:
    ///   - method: The HTTP method (e.g., `"GET"`, `"POST"`).
    ///   - path: The request path (e.g., `"/v1/vms"`).
    public func recordAPIRequest(method: String, path: String) {
        let key = "\(method) \(path)"
        apiRequestsTotal[key, default: 0] += 1
    }

    /// Records an API error response (4xx or 5xx).
    public func recordAPIError() {
        apiErrorsTotal += 1
    }

    /// Updates the current running VM count gauge.
    ///
    /// - Parameter count: The number of VMs currently running.
    public func updateVMCount(_ count: Int) {
        runningVMs = count
    }

    /// Updates the maximum VM count gauge.
    ///
    /// - Parameter count: The kernel-enforced maximum number of concurrent VMs.
    public func updateMaxVMs(_ count: Int) {
        maxVMs = count
    }

    /// Updates the free disk space gauge.
    ///
    /// - Parameter gb: Free disk space in gigabytes.
    public func updateFreeDisk(_ gb: Double) {
        freeDiskGB = gb
    }

    /// Records a completed SSH-ready latency measurement.
    ///
    /// - Parameter durationSeconds: Wall-clock duration from VM start to
    ///   SSH becoming available, in seconds.
    public func recordSSHReady(durationSeconds: Double) {
        sshReadyLatencySeconds.append(durationSeconds)
        let id = signpost.beginInterval("ssh-ready")
        signpost.endInterval("ssh-ready", id: id)
    }

    // MARK: - Runner Lifecycle Events

    /// Records the duration from VM boot to the runner registering with
    /// the orchestrator (e.g., GitHub Actions).
    ///
    /// - Parameter durationSeconds: Wall-clock duration from boot
    ///   completion to runner registration, in seconds.
    public func recordRunnerRegistered(durationSeconds: Double) {
        runnerRegistrationLatencySeconds.append(durationSeconds)
        let id = signpost.beginInterval("runner-registered")
        signpost.endInterval("runner-registered", id: id)
    }

    /// Records the duration from the runner becoming ready to the first
    /// job being picked up.
    ///
    /// - Parameter durationSeconds: Wall-clock duration from runner
    ///   ready to the first job starting, in seconds.
    public func recordTimeToFirstJob(durationSeconds: Double) {
        timeToFirstJobSeconds.append(durationSeconds)
        let id = signpost.beginInterval("time-to-first-job")
        signpost.endInterval("time-to-first-job", id: id)
    }

    /// Records the duration of a scrub (recycle) operation on a VM.
    ///
    /// - Parameter durationSeconds: Wall-clock duration of the scrub,
    ///   in seconds.
    public func recordScrubComplete(durationSeconds: Double) {
        scrubLatencySeconds.append(durationSeconds)
        let id = signpost.beginInterval("scrub")
        signpost.endInterval("scrub", id: id)
    }

    /// Records a cleanup failure event.
    ///
    /// Increments the cleanup failure counter and emits a point-in-time
    /// signpost event for tracing.
    public func recordCleanupFailure() {
        cleanupFailuresTotal += 1
        signpost.event("cleanup-failure")
    }

    // MARK: - Prometheus Text Format

    /// Generates the full metrics payload in Prometheus text exposition format.
    ///
    /// The output conforms to the
    /// [Prometheus exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/)
    /// specification, version 0.0.4. Each metric family includes `# HELP`
    /// and `# TYPE` comment lines followed by one or more sample lines.
    ///
    /// - Returns: A UTF-8 string suitable for serving at `/metrics` with
    ///   content type `text/plain; version=0.0.4; charset=utf-8`.
    public func prometheusText() -> String {
        var lines: [String] = []

        // --- Gauges ---

        lines.append("# HELP spooktacular_running_vms Current number of running VMs")
        lines.append("# TYPE spooktacular_running_vms gauge")
        lines.append("spooktacular_running_vms \(runningVMs)")
        lines.append("")

        lines.append("# HELP spooktacular_max_vms Maximum number of VMs (kernel limit)")
        lines.append("# TYPE spooktacular_max_vms gauge")
        lines.append("spooktacular_max_vms \(maxVMs)")
        lines.append("")

        lines.append("# HELP spooktacular_free_disk_gb Free disk space on host in gigabytes")
        lines.append("# TYPE spooktacular_free_disk_gb gauge")
        lines.append("spooktacular_free_disk_gb \(formatDouble(freeDiskGB))")
        lines.append("")

        // --- Counters ---

        lines.append("# HELP spooktacular_clones_total Total number of VM clone operations")
        lines.append("# TYPE spooktacular_clones_total counter")
        lines.append("spooktacular_clones_total \(clonesTotal)")
        lines.append("")

        lines.append("# HELP spooktacular_starts_total Total number of VM start operations")
        lines.append("# TYPE spooktacular_starts_total counter")
        lines.append("spooktacular_starts_total \(startsTotal)")
        lines.append("")

        lines.append("# HELP spooktacular_stops_total Total number of VM stop operations")
        lines.append("# TYPE spooktacular_stops_total counter")
        lines.append("spooktacular_stops_total \(stopsTotal)")
        lines.append("")

        lines.append("# HELP spooktacular_deletes_total Total number of VM delete operations")
        lines.append("# TYPE spooktacular_deletes_total counter")
        lines.append("spooktacular_deletes_total \(deletesTotal)")
        lines.append("")

        lines.append("# HELP spooktacular_api_requests_total Total API requests by method and path")
        lines.append("# TYPE spooktacular_api_requests_total counter")
        for (key, count) in apiRequestsTotal.sorted(by: { $0.key < $1.key }) {
            let parts = key.split(separator: " ", maxSplits: 1)
            let method = parts.count > 0 ? String(parts[0]) : "UNKNOWN"
            let path = parts.count > 1 ? String(parts[1]) : "/"
            lines.append("spooktacular_api_requests_total{method=\"\(method)\",path=\"\(path)\"} \(count)")
        }
        lines.append("")

        lines.append("# HELP spooktacular_api_errors_total Total API error responses")
        lines.append("# TYPE spooktacular_api_errors_total counter")
        lines.append("spooktacular_api_errors_total \(apiErrorsTotal)")
        lines.append("")

        // --- Summaries ---

        appendSummary(
            to: &lines,
            name: "spooktacular_clone_duration_seconds",
            help: "Duration of clone operations in seconds",
            values: cloneLatencySeconds
        )

        appendSummary(
            to: &lines,
            name: "spooktacular_boot_duration_seconds",
            help: "Duration of boot operations in seconds",
            values: bootLatencySeconds
        )

        appendSummary(
            to: &lines,
            name: "spooktacular_ssh_ready_duration_seconds",
            help: "Duration from VM start to SSH ready in seconds",
            values: sshReadyLatencySeconds
        )

        // --- Runner Lifecycle Summaries ---

        appendSummary(
            to: &lines,
            name: "spooktacular_runner_registration_duration_seconds",
            help: "Duration from boot to runner registration in seconds",
            values: runnerRegistrationLatencySeconds
        )

        appendSummary(
            to: &lines,
            name: "spooktacular_time_to_first_job_seconds",
            help: "Duration from runner ready to first job started in seconds",
            values: timeToFirstJobSeconds
        )

        appendSummary(
            to: &lines,
            name: "spooktacular_scrub_duration_seconds",
            help: "Duration of scrub/recycle operations in seconds",
            values: scrubLatencySeconds
        )

        // --- Runner Lifecycle Counters ---

        lines.append("# HELP spooktacular_cleanup_failures_total Total number of cleanup failures")
        lines.append("# TYPE spooktacular_cleanup_failures_total counter")
        lines.append("spooktacular_cleanup_failures_total \(cleanupFailuresTotal)")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    /// Appends a Prometheus summary metric (count + sum) to the output lines.
    ///
    /// - Parameters:
    ///   - lines: The output line buffer to append to.
    ///   - name: The metric name (e.g., `"spooktacular_clone_duration_seconds"`).
    ///   - help: The human-readable description for the `# HELP` line.
    ///   - values: The recorded sample values.
    private func appendSummary(
        to lines: inout [String],
        name: String,
        help: String,
        values: [Double]
    ) {
        lines.append("# HELP \(name) \(help)")
        lines.append("# TYPE \(name) summary")
        lines.append("\(name)_count \(values.count)")
        lines.append("\(name)_sum \(formatDouble(values.reduce(0, +)))")
        lines.append("")
    }

    /// Formats a `Double` for Prometheus output.
    ///
    /// Produces a string with up to three decimal places, trimming
    /// unnecessary trailing zeros. Whole numbers are rendered without
    /// a decimal point.
    private func formatDouble(_ value: Double) -> String {
        if value == value.rounded(.towardZero) && value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        // Up to 3 decimal places, no trailing zeros
        let formatted = String(format: "%.3f", value)
        var result = formatted
        while result.hasSuffix("0") {
            result = String(result.dropLast())
        }
        if result.hasSuffix(".") {
            result = String(result.dropLast())
        }
        return result
    }
}
