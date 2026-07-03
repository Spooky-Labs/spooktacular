import Testing
import Foundation
@testable import SpooktacularApplication

/// Tests for ``MetricsCollector`` — specifically the silent-failure
/// antipatterns fixed by the sweep: unbounded per-path cardinality
/// (now capped + overflow-bucketed), missing OTLP-failure counter,
/// and missing quantiles on summary output.
@Suite("MetricsCollector", .tags(.infrastructure))
struct MetricsCollectorTests {

    @Test("API-request cardinality is capped at the configured limit")
    func apiRequestCardinalityIsCapped() async {
        let collector = MetricsCollector(apiRequestsCardinalityLimit: 3)
        // First 3 distinct paths land in their own buckets.
        await collector.recordAPIRequest(method: "GET", path: "/a")
        await collector.recordAPIRequest(method: "GET", path: "/b")
        await collector.recordAPIRequest(method: "GET", path: "/c")
        // Path 4+ must collapse into OTHER so Prometheus cardinality
        // can't be pumped by an adversary hammering unique paths.
        await collector.recordAPIRequest(method: "GET", path: "/d")
        await collector.recordAPIRequest(method: "GET", path: "/e")

        let text = await collector.prometheusText()
        #expect(text.contains("path=\"/a\""))
        #expect(text.contains("path=\"/b\""))
        #expect(text.contains("path=\"/c\""))
        #expect(!text.contains("path=\"/d\""),
                "Paths beyond the limit must not create new buckets")
        #expect(text.contains("path=\"\(MetricsCollector.overflowPathBucket)\""),
                "Overflow paths must be bucketed into OTHER")
    }

    @Test("OTLP export failures appear as a counter in Prometheus output")
    func otlpExportFailureCounter() async {
        let collector = MetricsCollector()
        await collector.recordOTLPFailure()
        await collector.recordOTLPFailure()
        await collector.recordOTLPFailure()
        let text = await collector.prometheusText()
        #expect(text.contains("spooktacular_otlp_export_failures_total 3"),
                "Expected counter line; got:\n\(text)")
    }

    @Test("Summary quantiles reflect the recorded sample distribution")
    func summaryEmitsQuantiles() async {
        let collector = MetricsCollector()
        for value in [0.1, 0.5, 1.0, 2.0, 10.0] {
            await collector.recordClone(durationSeconds: value)
        }
        let text = await collector.prometheusText()
        #expect(text.contains("spooktacular_clone_duration_seconds{quantile=\"0.5\"}"))
        #expect(text.contains("spooktacular_clone_duration_seconds{quantile=\"0.9\"}"))
        #expect(text.contains("spooktacular_clone_duration_seconds{quantile=\"0.99\"}"))
    }

    @Test("Quantile helper matches the Prometheus nearest-rank interpolation")
    func quantileHelperBasics() {
        // sorted sample: [1, 2, 3, 4, 5] → p50 = 3
        let sorted = [1.0, 2.0, 3.0, 4.0, 5.0]
        #expect(MetricsCollector.quantile(sorted: sorted, p: 0.5) == 3.0)
        #expect(MetricsCollector.quantile(sorted: sorted, p: 0.0) == 1.0)
        #expect(MetricsCollector.quantile(sorted: sorted, p: 1.0) == 5.0)
        // Empty sample must return 0 without crashing
        #expect(MetricsCollector.quantile(sorted: [], p: 0.5) == 0)
    }
}
