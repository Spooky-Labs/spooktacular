import Foundation

/// Recycles a VM by deleting it and cloning a fresh copy from the source template.
///
/// This is the slowest but most thorough strategy. The sequence is:
/// 1. Stop the VM
/// 2. Delete the VM
/// 3. Clone a new VM from the source template
/// 4. Start the new VM
///
/// Validation checks the VM health endpoint.
public struct RecloneStrategy: RecycleStrategy {

    private let log: any LogProvider

    /// Creates a new reclone strategy.
    ///
    /// - Parameter log: Logger for diagnostic messages.
    public init(log: any LogProvider = SilentLogProvider()) {
        self.log = log
    }

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        log.info("Recycling VM '\(vm)' via reclone from '\(source)'")
        try await node.stop(vm: vm, on: endpoint)
        try await node.delete(vm: vm, on: endpoint)
        try await node.clone(vm: vm, from: source, on: endpoint)
        try await node.start(vm: vm, on: endpoint)
        log.info("Reclone complete for VM '\(vm)'")
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        try await node.health(vm: vm, on: endpoint)
    }
}
