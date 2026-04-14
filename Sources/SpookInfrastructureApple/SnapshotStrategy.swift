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

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        try await node.health(vm: vm, on: endpoint)
    }
}
