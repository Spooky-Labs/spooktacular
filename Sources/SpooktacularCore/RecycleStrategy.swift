import Foundation

/// The outcome of validating a VM after recycling.
///
/// ``RecycleStrategy`` implementations return a ``RecycleOutcome``
/// from ``RecycleStrategy/validate(vm:using:on:)`` to communicate
/// exactly why a VM is (or is not) safe for the next job. Callers
/// inspect the outcome and act deterministically:
///
/// | Outcome | Caller action |
/// |---------|---------------|
/// | ``readyForNextJob`` | Schedule the next job on this VM |
/// | ``needsRetry(reason:)`` | Recycle again, then revalidate |
/// | ``failed(reason:)`` | Destroy the VM — do **not** reuse |
///
/// ## Why not `Bool`?
///
/// A plain `Bool` cannot distinguish "the scrub left junk in /tmp"
/// (retryable) from "the guest agent is unreachable" (structural).
/// That distinction matters: the first is a nuisance, the second
/// means the VM may be compromised and must never serve another
/// tenant's job.
///
/// ## Invariant
///
/// After ``RecycleStrategy/recycle(vm:source:using:on:)`` returns,
/// the VM is in an *indeterminate* state — the cleanup script may
/// have partially executed, the snapshot restore may have left
/// residual mounts, etc. Callers **MUST** call
/// ``RecycleStrategy/validate(vm:using:on:)`` and act on the
/// returned ``RecycleOutcome``. Returning a VM to the warm pool
/// without a ``readyForNextJob`` outcome is a correctness bug.
public enum RecycleOutcome: Sendable, Equatable {

    /// The VM passed all post-recycle checks and is safe to schedule
    /// for the next job.
    case readyForNextJob

    /// Validation detected a recoverable condition (e.g. `/tmp` not
    /// empty, stale runner process). The caller may re-run
    /// ``RecycleStrategy/recycle(vm:source:using:on:)`` and then
    /// ``RecycleStrategy/validate(vm:using:on:)`` a second time.
    ///
    /// - Parameter reason: A human-readable description of the
    ///   specific validation failure. Safe to log and surface in
    ///   audit records.
    case needsRetry(reason: String)

    /// Validation detected a structural failure that retrying will
    /// not fix (e.g. guest agent unreachable, disk corruption).
    /// The caller **MUST** destroy the VM.
    ///
    /// - Parameter reason: A human-readable description of the
    ///   structural failure.
    case failed(reason: String)
}

/// A strategy for recycling a VM between runner jobs.
///
/// Recycling prepares a VM for reuse after a job completes. Different
/// strategies trade off speed versus isolation:
///
/// | Strategy | Speed | Isolation | Mechanism |
/// |----------|-------|-----------|-----------|
/// | ``ScrubStrategy`` | Fastest | Lowest | In-place cleanup script |
/// | ``SnapshotStrategy`` | Medium | High | Snapshot restore |
/// | ``RecloneStrategy`` | Slowest | Highest | Full delete and re-clone |
///
/// ## Contract
///
/// 1. ``recycle(vm:source:using:on:)`` may leave the VM in an
///    indeterminate state — partial cleanup, mid-restore, etc.
/// 2. The caller **MUST** then call ``validate(vm:using:on:)``
///    and inspect the ``RecycleOutcome``.
/// 3. Only ``RecycleOutcome/readyForNextJob`` permits returning
///    the VM to the warm pool.
///
/// ## Clean Architecture
///
/// This protocol is defined in the Interfaces layer. Concrete
/// implementations (``RecloneStrategy``, ``SnapshotStrategy``,
/// ``ScrubStrategy``) live in the Infrastructure layer and may
/// import framework dependencies like `os.Logger`.
public protocol RecycleStrategy: Sendable {

    /// Recycles a VM so it is ready for the next job.
    ///
    /// On return, the VM is in an *indeterminate* state. The caller
    /// MUST call ``validate(vm:using:on:)`` before scheduling new
    /// work on this VM.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to recycle.
    ///   - source: The source template name (used by clone-based strategies).
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws

    /// Validates that a recycled VM is ready for the next job.
    ///
    /// Each strategy implements a set of checks appropriate to its
    /// isolation guarantees (``ScrubStrategy`` inspects guest state;
    /// ``RecloneStrategy`` runs a health check; ``SnapshotStrategy``
    /// runs a health check after the restore).
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to validate.
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    /// - Returns: A ``RecycleOutcome`` describing the post-recycle state.
    func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> RecycleOutcome
}

// MARK: - RecycleError

/// Errors that can occur during VM recycling.
public enum RecycleError: Error, LocalizedError, Sendable {

    /// The scrub cleanup script failed with a non-zero exit code.
    case scrubFailed(vm: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .scrubFailed(vm, exitCode, stderr):
            "Scrub failed for VM '\(vm)' with exit code \(exitCode): \(stderr)"
        }
    }
}
