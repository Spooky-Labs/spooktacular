import Foundation
import os

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
/// Implement ``recycle(vm:source:using:on:)`` to perform the actual
/// recycling, and ``validate(vm:using:on:)`` to confirm the VM is
/// ready for the next job.
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
    ///
    /// - Parameters:
    ///   - vm: The name of the VM that failed scrubbing.
    ///   - exitCode: The process exit code from the cleanup script.
    ///   - stderr: The standard error output from the cleanup script.
    case scrubFailed(vm: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .scrubFailed(vm, exitCode, stderr):
            "Scrub failed for VM '\(vm)' with exit code \(exitCode): \(stderr)"
        }
    }
}

// MARK: - RecloneStrategy

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

    private let logger = Logger(subsystem: "com.spooktacular", category: "recycle.reclone")

    /// Creates a new reclone strategy.
    public init() {}

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        logger.info("Recycling VM '\(vm, privacy: .public)' via reclone from '\(source, privacy: .public)'")

        try await node.stop(vm: vm, on: endpoint)
        logger.debug("Stopped VM '\(vm, privacy: .public)'")

        try await node.delete(vm: vm, on: endpoint)
        logger.debug("Deleted VM '\(vm, privacy: .public)'")

        try await node.clone(vm: vm, from: source, on: endpoint)
        logger.debug("Cloned VM '\(vm, privacy: .public)' from '\(source, privacy: .public)'")

        try await node.start(vm: vm, on: endpoint)
        logger.info("Reclone complete for VM '\(vm, privacy: .public)'")
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        let healthy = try await node.health(vm: vm, on: endpoint)
        logger.info("Health check for VM '\(vm, privacy: .public)': \(healthy, privacy: .public)")
        return healthy
    }
}

// MARK: - SnapshotStrategy

/// Recycles a VM by restoring a named snapshot.
///
/// This is a middle-ground strategy that provides high isolation
/// (the disk is reverted to a known-good state) with better
/// performance than a full reclone on APFS volumes. The sequence is:
/// 1. Stop the VM
/// 2. Restore the named snapshot
/// 3. Start the VM
///
/// Validation checks the VM health endpoint.
public struct SnapshotStrategy: RecycleStrategy {

    private let logger = Logger(subsystem: "com.spooktacular", category: "recycle.snapshot")

    /// The name of the snapshot to restore during recycling.
    public let snapshotName: String

    /// Creates a new snapshot strategy.
    ///
    /// - Parameter snapshotName: The name of the snapshot to restore.
    public init(snapshotName: String) {
        self.snapshotName = snapshotName
    }

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        logger.info("Recycling VM '\(vm, privacy: .public)' via snapshot '\(self.snapshotName, privacy: .public)'")

        try await node.stop(vm: vm, on: endpoint)
        logger.debug("Stopped VM '\(vm, privacy: .public)'")

        try await node.restoreSnapshot(vm: vm, snapshot: snapshotName, on: endpoint)
        logger.debug("Restored snapshot '\(self.snapshotName, privacy: .public)' on VM '\(vm, privacy: .public)'")

        try await node.start(vm: vm, on: endpoint)
        logger.info("Snapshot restore complete for VM '\(vm, privacy: .public)'")
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        let healthy = try await node.health(vm: vm, on: endpoint)
        logger.info("Health check for VM '\(vm, privacy: .public)': \(healthy, privacy: .public)")
        return healthy
    }
}

// MARK: - ScrubStrategy

/// Recycles a VM by running an in-place cleanup script inside the guest.
///
/// This is the fastest strategy but provides the least isolation.
/// The cleanup script performs:
/// - Kill all user processes
/// - Remove the runner work directory
/// - Clear the clipboard
/// - Remove temporary files
///
/// If the cleanup script exits with a non-zero code, a
/// ``RecycleError/scrubFailed(vm:exitCode:stderr:)`` error is thrown.
///
/// Validation runs a verification script that checks for leftover
/// processes, work directories, and clipboard contents. Returns `true`
/// only if the exit code is zero.
public struct ScrubStrategy: RecycleStrategy {

    private let logger = Logger(subsystem: "com.spooktacular", category: "recycle.scrub")

    /// The cleanup script executed inside the guest to scrub VM state.
    private let cleanupScript = """
        killall -u runner 2>/dev/null || true; \
        rm -rf /Users/runner/work; \
        pbcopy < /dev/null; \
        rm -rf /tmp/* /var/folders/*/*/* 2>/dev/null || true
        """

    /// The validation script executed inside the guest to verify scrub success.
    private let validationScript = """
        pgrep -u runner > /dev/null 2>&1 && exit 1; \
        [ -d /Users/runner/work ] && exit 1; \
        [ -n "$(pbpaste 2>/dev/null)" ] && exit 1; \
        exit 0
        """

    /// Creates a new scrub strategy.
    public init() {}

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        logger.info("Recycling VM '\(vm, privacy: .public)' via scrub")

        let result = try await node.execInGuest(vm: vm, command: cleanupScript, on: endpoint)

        guard result.exitCode == 0 else {
            logger.error(
                "Scrub failed for VM '\(vm, privacy: .public)': exit \(result.exitCode) — \(result.stderr, privacy: .public)"
            )
            throw RecycleError.scrubFailed(vm: vm, exitCode: result.exitCode, stderr: result.stderr)
        }

        logger.info("Scrub complete for VM '\(vm, privacy: .public)'")
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        let result = try await node.execInGuest(vm: vm, command: validationScript, on: endpoint)
        let valid = result.exitCode == 0
        logger.info("Scrub validation for VM '\(vm, privacy: .public)': \(valid, privacy: .public)")
        return valid
    }
}
