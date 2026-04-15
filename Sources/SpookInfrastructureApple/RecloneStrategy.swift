import Foundation
import SpookCore
import SpookApplication

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

    /// Recycles the VM and validates the result. If validation fails,
    /// destroys the VM to prevent dirty reuse.
    ///
    /// When a ``ReusePolicy`` is provided and ``ReusePolicy/warmPoolAllowed``
    /// is `false`, the VM is destroyed immediately without attempting a
    /// recycle — enforcing ephemeral mode in multi-tenant deployments.
    ///
    /// Because reclone produces a fresh clone, validation is a simple
    /// health check. A healthy clone always returns ``RecycleResult/clean``.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to recycle.
    ///   - source: The source template name used for cloning.
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    ///   - reusePolicy: Optional reuse policy. When warm-pool reuse is
    ///     disallowed, the VM is destroyed instead of recycled.
    /// - Returns: ``RecycleResult/clean`` after a successful health check,
    ///   or ``RecycleResult/destroyed`` if validation failed or reuse
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
        let valid = try await validate(vm: vm, using: node, on: endpoint)
        if valid {
            log.info("VM '\(vm)' passed reclone health check")
            return .clean
        }
        log.error("VM '\(vm)' failed reclone health check — destroying")
        try await node.stop(vm: vm, on: endpoint)
        try await node.delete(vm: vm, on: endpoint)
        return .destroyed
    }
}
