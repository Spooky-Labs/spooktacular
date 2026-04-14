import Foundation

/// The top-level GitHub `workflow_job` webhook payload.
///
/// GitHub sends this payload when a workflow job is queued, starts running,
/// or completes. The ``action`` field indicates which lifecycle event occurred,
/// and ``workflowJob`` contains the job details.
///
/// ## Usage
///
/// ```swift
/// let event = try JSONDecoder().decode(WorkflowJobWebhook.self, from: data)
/// switch event.action {
/// case .queued:      print("Job queued")
/// case .inProgress:  print("Job running on \(event.workflowJob.runnerName ?? "unknown")")
/// case .completed:   print("Job finished: \(event.workflowJob.conclusion ?? "unknown")")
/// case .other(let v): print("Unhandled action: \(v)")
/// }
/// ```
public struct WorkflowJobWebhook: Codable, Sendable {

    /// The webhook action that triggered this delivery.
    public let action: Action

    /// The workflow job associated with this webhook event.
    public let workflowJob: WorkflowJob

    /// The set of recognised `workflow_job` webhook actions.
    ///
    /// Unknown actions are captured as ``other(_:)`` so the model is
    /// forward-compatible with future GitHub API changes.
    public enum Action: Codable, Sendable, Equatable {

        /// A new job has been queued and is waiting for a runner.
        case queued

        /// A runner has picked up the job and execution has begun.
        case inProgress

        /// The job has finished (check ``WorkflowJob/conclusion`` for the result).
        case completed

        /// An action not yet modelled by this enum.
        case other(String)

        public init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            switch raw {
            case "queued":      self = .queued
            case "in_progress": self = .inProgress
            case "completed":   self = .completed
            default:            self = .other(raw)
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .queued:        try container.encode("queued")
            case .inProgress:    try container.encode("in_progress")
            case .completed:     try container.encode("completed")
            case .other(let v):  try container.encode(v)
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case action
        case workflowJob = "workflow_job"
    }
}

/// A workflow job from the GitHub webhook payload.
///
/// Contains identifying information about the job, its current status,
/// and the runner assigned to it (if any). The ``labels`` array lists
/// the runner labels the job was configured to target.
public struct WorkflowJob: Codable, Sendable {

    /// The unique identifier for this job.
    public let id: Int

    /// The identifier of the workflow run this job belongs to.
    public let runId: Int

    /// The name of the runner executing this job, or `nil` if not yet assigned.
    public let runnerName: String?

    /// The numeric identifier of the runner, or `nil` if not yet assigned.
    public let runnerId: Int?

    /// The current status of the job (e.g. `"queued"`, `"in_progress"`, `"completed"`).
    public let status: String

    /// The conclusion of the job once completed (e.g. `"success"`, `"failure"`),
    /// or `nil` while the job is still running.
    public let conclusion: String?

    /// The runner labels this job targets (e.g. `["self-hosted", "macOS", "ARM64"]`).
    public let labels: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case runnerName = "runner_name"
        case runnerId = "runner_id"
        case status, conclusion, labels
    }
}
