import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - Webhook Event Tests

/// Validates ``WorkflowJobWebhook`` decoding from GitHub `workflow_job`
/// webhook payloads, covering every action variant and optional fields.
@Suite("WebhookEvent")
struct WebhookEventTests {

    @Test("Parse workflow_job in_progress")
    func parseInProgress() throws {
        let json = """
        {"action":"in_progress","workflow_job":{"id":123,"run_id":456,"runner_name":"spooktacular-runner-001","runner_id":789,"status":"in_progress","labels":["self-hosted","macOS","ARM64"]}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .inProgress)
        #expect(event.workflowJob.runnerName == "spooktacular-runner-001")
        #expect(event.workflowJob.runnerId == 789)
    }

    @Test("Parse workflow_job completed with conclusion")
    func parseCompleted() throws {
        let json = """
        {"action":"completed","workflow_job":{"id":123,"run_id":456,"runner_name":"r1","runner_id":789,"status":"completed","conclusion":"success","labels":["self-hosted"]}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .completed)
        #expect(event.workflowJob.conclusion == "success")
    }

    @Test("Parse workflow_job queued (no runner yet)")
    func parseQueued() throws {
        let json = """
        {"action":"queued","workflow_job":{"id":123,"run_id":456,"status":"queued","labels":["self-hosted","macOS"]}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .queued)
        #expect(event.workflowJob.runnerName == nil)
    }

    @Test("Unknown action decoded as .other")
    func unknownAction() throws {
        let json = """
        {"action":"waiting","workflow_job":{"id":1,"run_id":2,"status":"waiting","labels":[]}}
        """.data(using: .utf8)!
        let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: json)
        #expect(event.action == .other("waiting"))
    }
}
