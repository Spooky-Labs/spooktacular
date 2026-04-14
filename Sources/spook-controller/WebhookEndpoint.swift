import Foundation
import os
import SpooktacularKit

/// HTTP endpoint for receiving GitHub webhooks.
///
/// Thin adapter: receives POST, verifies HMAC signature via
/// ``WebhookSignatureVerifier``, parses ``WorkflowJobWebhook``,
/// and forwards to the pool reconciler. No business logic.
enum WebhookEndpoint {

    private static let logger = Logger(subsystem: "com.spooktacular.controller", category: "webhook")

    /// Handles an incoming webhook request.
    ///
    /// After verifying the HMAC signature and parsing the payload, dispatches
    /// `workflow_job` events to the ``RunnerPoolReconciler`` so that the
    /// matching runner's ``RunnerStateMachine`` receives `.jobStarted` or
    /// `.jobCompleted`.
    ///
    /// - Parameters:
    ///   - body: Raw HTTP request body.
    ///   - headers: HTTP headers (case-insensitive lookup).
    ///   - secret: The webhook HMAC secret.
    ///   - reconciler: The pool reconciler to dispatch events to.
    /// - Returns: HTTP status code to return to GitHub.
    static func handle(
        body: Data,
        headers: [String: String],
        secret: String,
        reconciler: RunnerPoolReconciler? = nil
    ) async -> Int {
        // 1. Verify signature
        let signature = headers["x-hub-signature-256"]
            ?? headers["X-Hub-Signature-256"] ?? ""
        guard WebhookSignatureVerifier.verify(body: body, signature: signature, secret: secret, hmac: CryptoKitHMACProvider()) else {
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

        // 4. Dispatch to RunnerPoolReconciler.
        //    Only in_progress and completed actions map to state machine events;
        //    the reconciler handles the filtering internally.
        if let reconciler {
            await reconciler.dispatchWebhook(event)
        }

        return 200
    }
}
