import Foundation

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
/// ## Clean Architecture
///
/// This protocol is defined in the Interfaces layer. Concrete
/// implementations (``RecloneStrategy``, ``SnapshotStrategy``,
/// ``ScrubStrategy``) live in the Infrastructure layer and may
/// import framework dependencies like `os.Logger`.
public protocol RecycleStrategy: Sendable {

    /// Recycles a VM so it is ready for the next job.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to recycle.
    ///   - source: The source template name (used by clone-based strategies).
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws

    /// Validates that a recycled VM is ready for the next job.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to validate.
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    /// - Returns: `true` if the VM passes validation, `false` otherwise.
    func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool
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
