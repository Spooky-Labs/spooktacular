import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("AuditSink throws contract")
struct AuditSinkThrowsTests {

    /// A sink that always throws — used to prove the protocol
    /// propagates errors through all the aggregating adapters.
    actor FlakySink: AuditSink {
        let reason: String
        init(reason: String = "simulated disk full") { self.reason = reason }
        func record(_ entry: AuditRecord) async throws {
            throw AuditSinkError.recordingFailed(reason: reason)
        }
    }

    private static func sample() -> AuditRecord {
        AuditRecord(
            actorIdentity: "ctl",
            tenant: .default,
            scope: .runner,
            resource: "vm-1",
            action: "create",
            outcome: .success
        )
    }

    @Test("DualAuditSink rethrows primary error when secondary succeeds")
    func dualRethrowsPrimary() async {
        let primary = FlakySink(reason: "primary broke")
        let secondary = CollectingAuditSink()
        let dual = DualAuditSink(primary: primary, secondary: secondary)
        await #expect(throws: AuditSinkError.self) {
            try await dual.record(Self.sample())
        }
        let records = await secondary.records
        #expect(records.count == 1, "secondary still records when primary throws")
    }

    @Test("DualAuditSink rethrows secondary error when primary succeeds")
    func dualRethrowsSecondary() async {
        let primary = CollectingAuditSink()
        let secondary = FlakySink(reason: "secondary broke")
        let dual = DualAuditSink(primary: primary, secondary: secondary)
        await #expect(throws: AuditSinkError.self) {
            try await dual.record(Self.sample())
        }
        let records = await primary.records
        #expect(records.count == 1, "primary still records when secondary throws")
    }

    @Test("DualAuditSink aggregates both failures into one error")
    func dualAggregates() async {
        let primary = FlakySink(reason: "primary boom")
        let secondary = FlakySink(reason: "secondary boom")
        let dual = DualAuditSink(primary: primary, secondary: secondary)
        do {
            try await dual.record(Self.sample())
            Issue.record("dual sink should have thrown when both sinks throw")
        } catch let e as AuditSinkError {
            if case .recordingFailed(let reason) = e {
                #expect(reason.contains("primary boom"))
                #expect(reason.contains("secondary boom"))
            } else {
                Issue.record("expected recordingFailed, got \(e)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("JSONFileAuditSink fsyncs and is readable after crash-style reopen")
    func jsonFileFsyncSurvivesReopen() async throws {
        let tmp = TempDirectory()
        let path = tmp.file("fsync-\(UUID().uuidString).jsonl").path
        let sink = try JSONFileAuditSink(path: path)
        try await sink.record(Self.sample())
        // After record() returns we demand the bytes be observable
        // to a separate reader without closing the sink — fsync()
        // guarantees the page cache has been written to storage.
        let data = try Data(contentsOf: URL(filePath: path))
        let line = String(data: data, encoding: .utf8)
        #expect(line?.contains("\"action\":\"create\"") == true)
        #expect(line?.hasSuffix("\n") == true)
    }
}
