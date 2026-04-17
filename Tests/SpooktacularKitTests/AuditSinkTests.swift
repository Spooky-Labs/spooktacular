import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("AuditSink")
struct AuditSinkTests {

    @Test("JSONFileAuditSink writes valid JSONL")
    func jsonFileWritesJSONL() async throws {
        let tmpPath = NSTemporaryDirectory() + "audit-test-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let sink = try JSONFileAuditSink(path: tmpPath)

        let record = AuditRecord(
            actorIdentity: "test-controller",
            tenant: TenantID("blue"),
            scope: .runner,
            resource: "vm-001",
            action: "deleteVM",
            outcome: .success,
            correlationID: "req-123"
        )

        try await sink.record(record)

        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        let line = String(data: data, encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)

        // Verify it's valid JSON
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        #expect(json["action"] as? String == "deleteVM")
        #expect(json["resource"] as? String == "vm-001")
        #expect(json["actorIdentity"] as? String == "test-controller")
        #expect(json["outcome"] as? String == "success")
    }

    @Test("JSONFileAuditSink creates file if missing")
    func jsonFileCreatesFile() async throws {
        let tmpPath = NSTemporaryDirectory() + "audit-create-\(UUID().uuidString)/nested/audit.jsonl"
        defer { try? FileManager.default.removeItem(atPath: (tmpPath as NSString).deletingLastPathComponent) }

        let sink = try JSONFileAuditSink(path: tmpPath)
        let record = AuditRecord(
            actorIdentity: "test",
            tenant: .default,
            scope: .read,
            resource: "health",
            action: "healthCheck",
            outcome: .success
        )
        try await sink.record(record)

        #expect(FileManager.default.fileExists(atPath: tmpPath))
    }

    @Test("AuditRecord captures all required fields")
    func auditRecordFields() {
        let context = AuthorizationContext(
            actorIdentity: "ctrl-1",
            tenant: TenantID("red"),
            scope: .breakGlass,
            resource: "vm-exec",
            action: "exec",
            requestID: "req-456"
        )
        let record = AuditRecord(context: context, outcome: .denied)

        #expect(record.actorIdentity == "ctrl-1")
        #expect(record.tenant == TenantID("red"))
        #expect(record.scope == .breakGlass)
        #expect(record.resource == "vm-exec")
        #expect(record.action == "exec")
        #expect(record.outcome == .denied)
        #expect(record.correlationID == "req-456")
    }
}
