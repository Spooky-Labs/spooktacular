import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

@Suite("Audit Pipeline", .tags(.audit, .compliance, .integration))
struct AuditPipelineTests {

    // MARK: - Helpers

    /// Creates a sample `AuditRecord` with a unique resource identifier.
    private static func sampleRecord(index: Int = 0) -> AuditRecord {
        AuditRecord(
            actorIdentity: "actor-\(index)",
            tenant: .default,
            scope: .runner,
            resource: "vm-\(index)",
            action: "start",
            outcome: .success,
            correlationID: "corr-\(index)"
        )
    }

    // MARK: - Append-Only Store

    @Suite("Append-Only Store")
    struct AppendOnly {

        @Test("records are readable after append", .timeLimit(.minutes(1)))
        func readAfterAppend() async throws {
            let tmpDir = TempDirectory()
            let filePath = tmpDir.file("audit-ro.jsonl").path
            let store = try AppendOnlyFileAuditStore(path: filePath)

            let record = AuditPipelineTests.sampleRecord(index: 42)
            let seq = try await store.append(record)
            #expect(seq == 0, "First record should have sequence number 0")

            let read = try await store.read(from: 0, count: 1)
            #expect(read.count == 1, "Should read back one record")
            #expect(read[0].actorIdentity == "actor-42")
            #expect(read[0].resource == "vm-42")
            #expect(read[0].outcome == .success)
        }

        @Test("sequence numbers are monotonic after N appends", arguments: [1, 10, 100])
        func monotonicSequence(count: Int) async throws {
            let tmpDir = TempDirectory()
            let filePath = tmpDir.file("audit-mono-\(count).jsonl").path
            let store = try AppendOnlyFileAuditStore(path: filePath)

            var sequences: [UInt64] = []
            for i in 0..<count {
                let seq = try await store.append(AuditPipelineTests.sampleRecord(index: i))
                sequences.append(seq)
            }

            // Verify monotonically increasing sequence numbers.
            for i in 1..<sequences.count {
                #expect(sequences[i] > sequences[i - 1],
                        "Sequence \(sequences[i]) must be greater than \(sequences[i - 1])")
            }

            // Verify final record count.
            let totalCount = try await store.recordCount()
            #expect(totalCount == UInt64(count),
                    "Record count must equal the number of appends")

            // Verify all records are readable.
            let allRecords = try await store.read(from: 0, count: count)
            #expect(allRecords.count == count,
                    "Should read back all \(count) records")
        }
    }

    // MARK: - Dual Sink

    @Suite("Dual Sink")
    struct DualSinkTests {

        @Test("dual sink forwards to both sinks")
        func forwardsToBoth() async throws {
            let primary = CollectingAuditSink()
            let secondary = CollectingAuditSink()
            let dual = DualAuditSink(primary: primary, secondary: secondary)

            let record = AuditPipelineTests.sampleRecord(index: 7)
            try await dual.record(record)

            let primaryRecords = await primary.records
            let secondaryRecords = await secondary.records

            #expect(primaryRecords.count == 1,
                    "Primary sink should receive exactly one record")
            #expect(secondaryRecords.count == 1,
                    "Secondary sink should receive exactly one record")

            #expect(primaryRecords[0].actorIdentity == "actor-7")
            #expect(secondaryRecords[0].actorIdentity == "actor-7")
            #expect(primaryRecords[0].resource == "vm-7")
            #expect(secondaryRecords[0].resource == "vm-7")
        }

        @Test("dual sink forwards multiple records in order")
        func forwardsMultiple() async throws {
            let primary = CollectingAuditSink()
            let secondary = CollectingAuditSink()
            let dual = DualAuditSink(primary: primary, secondary: secondary)

            for i in 0..<5 {
                try await dual.record(AuditPipelineTests.sampleRecord(index: i))
            }

            let pRecords = await primary.records
            let sRecords = await secondary.records

            #expect(pRecords.count == 5)
            #expect(sRecords.count == 5)

            for i in 0..<5 {
                #expect(pRecords[i].actorIdentity == "actor-\(i)")
                #expect(sRecords[i].actorIdentity == "actor-\(i)")
            }
        }
    }
}
