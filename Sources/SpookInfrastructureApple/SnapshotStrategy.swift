import Foundation
import SpookCore
import SpookApplication

/// Recycles a VM by restoring a named snapshot.
///
/// Middle-ground strategy: high isolation (disk reverted to known-good state)
/// with better performance than a full reclone. The sequence is:
/// 1. Stop the VM
/// 2. Restore the named snapshot
/// 3. Start the VM
public struct SnapshotStrategy: RecycleStrategy {

    private let log: any LogProvider

    /// The name of the snapshot to restore during recycling.
    public let snapshotName: String

    /// Creates a new snapshot strategy.
    ///
    /// - Parameters:
    ///   - snapshotName: The name of the snapshot to restore.
    ///   - log: Logger for diagnostic messages.
    public init(snapshotName: String, log: any LogProvider = SilentLogProvider()) {
        self.snapshotName = snapshotName
        self.log = log
    }

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        log.info("Recycling VM '\(vm)' via snapshot '\(snapshotName)'")
        try await node.stop(vm: vm, on: endpoint)
        try await node.restoreSnapshot(vm: vm, snapshot: snapshotName, on: endpoint)
        try await node.start(vm: vm, on: endpoint)
        log.info("Snapshot restore complete for VM '\(vm)'")
    }

    /// Validates a snapshot-restored VM by running the node-level
    /// health check.
    ///
    /// A snapshot restore produces a known-good disk state, so we do
    /// not need to inspect guest internals the way ``ScrubStrategy``
    /// does. The only way a snapshot restore can produce an unsafe
    /// VM is if the VM failed to boot — that is a structural failure
    /// (``RecycleOutcome/failed(reason:)``), not a retryable one.
    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> RecycleOutcome {
        let healthy: Bool
        do {
            healthy = try await node.health(vm: vm, on: endpoint)
        } catch {
            return .failed(reason: "health check threw: \(error.localizedDescription)")
        }
        return healthy
            ? .readyForNextJob
            : .failed(reason: "health check returned false after snapshot restore")
    }

    /// Recycles the VM and validates the result. If validation fails,
    /// destroys the VM to prevent dirty reuse.
    ///
    /// When a ``ReusePolicy`` is provided and ``ReusePolicy/warmPoolAllowed``
    /// is `false`, the VM is destroyed immediately without attempting a
    /// snapshot restore — enforcing ephemeral mode in multi-tenant deployments.
    ///
    /// Restores the snapshot, boots the VM, then runs a health check.
    /// If the health check fails the VM is stopped and deleted.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to recycle.
    ///   - source: The source template name (used if a fresh clone is needed later).
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    ///   - reusePolicy: Optional reuse policy. When warm-pool reuse is
    ///     disallowed, the VM is destroyed instead of recycled.
    /// - Returns: ``RecycleResult/clean`` if health passes,
    ///   ``RecycleResult/destroyed`` if health failed or reuse
    ///   is disallowed.
    public func recycleWithValidation(
        vm: String,
        source: String,
        using node: any NodeClient,
        on endpoint: URL,
        reusePolicy: ReusePolicy? = nil
    ) async throws -> RecycleResult {
        // If reuse policy forbids warm-pool reuse, destroy immediately.
        if let policy = reusePolicy, !policy.warmPoolAllowed {
            log.info("VM '\(vm)' warm-pool reuse disallowed by policy — destroying")
            try await node.stop(vm: vm, on: endpoint)
            try await node.delete(vm: vm, on: endpoint)
            return .destroyed
        }

        try await recycle(vm: vm, source: source, using: node, on: endpoint)
        let outcome = try await validate(vm: vm, using: node, on: endpoint)
        switch outcome {
        case .readyForNextJob:
            log.info("VM '\(vm)' passed snapshot health check")
            return .clean
        case .needsRetry(let reason), .failed(let reason):
            log.error("VM '\(vm)' failed snapshot health check — destroying. Reason: \(reason)")
            try await node.stop(vm: vm, on: endpoint)
            try await node.delete(vm: vm, on: endpoint)
            return .destroyed
        }
    }
}
