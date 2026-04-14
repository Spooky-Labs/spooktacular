import Foundation
import os
import SpooktacularKit

/// HTTP endpoint for receiving GitHub webhooks.
///
/// Thin adapter: receives POST, verifies HMAC signature via
/// ``WebhookSignatureVerifier``, parses ``WorkflowJobWebhook``,
/// and forwards to the pool manager. No business logic.
enum WebhookEndpoint {

    private static let logger = Logger(subsystem: "com.spooktacular.controller", category: "webhook")

    /// Handles an incoming webhook request.
    ///
    /// - Parameters:
    ///   - body: Raw HTTP request body.
    ///   - headers: HTTP headers (case-insensitive lookup).
    ///   - secret: The webhook HMAC secret.
    /// - Returns: HTTP status code to return to GitHub.
    static func handle(body: Data, headers: [String: String], secret: String) -> Int {
        // 1. Verify signature
        let signature = headers["x-hub-signature-256"]
            ?? headers["X-Hub-Signature-256"] ?? ""
        guard WebhookSignatureVerifier.verify(body: body, signature: signature, secret: secret) else {
            logger.warning("Webhook signature verification failed")
            return 401
        }

        // 2. Filter event type
        let eventType = headers["x-github-event"]
            ?? headers["X-GitHub-Event"] ?? ""
        guard eventType == "workflow_job" else {
            logger.debug("Ignoring webhook event type: \(eventType, privacy: .public)")
            return 200
        }

        // 3. Parse payload
        guard let event = try? JSONDecoder().decode(WorkflowJobWebhook.self, from: body) else {
            logger.error("Failed to parse workflow_job webhook payload")
            return 400
        }

        logger.info("Webhook: workflow_job.\(String(describing: event.action), privacy: .public) runner=\(event.workflowJob.runnerName ?? "nil", privacy: .public)")

        // 4. Event dispatch to RunnerPoolManager will be wired here
        // when the pool reconciler's event ingestion API is complete.
        return 200
    }
}
