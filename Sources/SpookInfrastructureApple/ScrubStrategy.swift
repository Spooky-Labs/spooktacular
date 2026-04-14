import Foundation
import SpookCore
import SpookApplication

/// The outcome of a ``recycleWithValidation(vm:source:using:on:)`` call.
///
/// Callers inspect this to decide whether the VM is safe to schedule
/// new work on (``clean``) or whether it was destroyed because it
/// failed post-recycle validation (``destroyed``).
public enum RecycleResult: Sendable {
    /// The VM passed validation and is safe to reuse.
    case clean
    /// Validation failed; the VM was stopped and deleted to prevent dirty reuse.
    case destroyed
}

/// Recycles a VM by running an in-place cleanup script inside the guest.
///
/// Fastest strategy, lowest isolation. The cleanup script kills user
/// processes, removes the runner work directory, clears the clipboard,
/// and removes temp files. If cleanup fails, throws ``RecycleError``.
///
/// Validation runs a verification script checking for leftover state.
/// Returns `true` only if the VM is confirmed clean.
public struct ScrubStrategy: RecycleStrategy {

    private let log: any LogProvider

    private let cleanupScript = """
        killall -u runner 2>/dev/null || true; \
        rm -rf /Users/runner/work; \
        pbcopy < /dev/null; \
        rm -rf /tmp/* /var/folders/*/*/* 2>/dev/null || true
        """

    private let validationScript = """
        pgrep -u runner > /dev/null 2>&1 && exit 1; \
        [ -d /Users/runner/work ] && exit 1; \
        [ -n "$(pbpaste 2>/dev/null)" ] && exit 1; \
        exit 0
        """

    /// Creates a new scrub strategy.
    ///
    /// - Parameter log: Logger for diagnostic messages.
    public init(log: any LogProvider = SilentLogProvider()) {
        self.log = log
    }

    public func recycle(vm: String, source: String, using node: any NodeClient, on endpoint: URL) async throws {
        log.info("Recycling VM '\(vm)' via scrub")
        let result = try await node.execInGuest(vm: vm, command: cleanupScript, on: endpoint)
        guard result.exitCode == 0 else {
            log.error("Scrub failed for VM '\(vm)': exit \(result.exitCode)")
            throw RecycleError.scrubFailed(vm: vm, exitCode: result.exitCode, stderr: result.stderr)
        }
        log.info("Scrub complete for VM '\(vm)'")
    }

    public func validate(vm: String, using node: any NodeClient, on endpoint: URL) async throws -> Bool {
        let result = try await node.execInGuest(vm: vm, command: validationScript, on: endpoint)
        return result.exitCode == 0
    }

    /// Recycles the VM and validates the result. If validation fails,
    /// destroys the VM to prevent dirty reuse.
    ///
    /// This is the only method callers should use. Direct calls to
    /// `recycle()` without validation are unsafe for production.
    ///
    /// - Parameters:
    ///   - vm: The name of the VM to recycle.
    ///   - source: The source template name (unused by scrub, but required by the protocol).
    ///   - node: A ``NodeClient`` to communicate with the node.
    ///   - endpoint: The endpoint URL of the node.
    /// - Returns: ``RecycleResult/clean`` if validation passes,
    ///   ``RecycleResult/destroyed`` if validation failed and the VM was torn down.
    public func recycleWithValidation(
        vm: String,
        source: String,
        using node: any NodeClient,
        on endpoint: URL
    ) async throws -> RecycleResult {
        try await recycle(vm: vm, source: source, using: node, on: endpoint)
        let valid = try await validate(vm: vm, using: node, on: endpoint)
        if valid {
            log.info("VM '\(vm)' passed scrub validation")
            return .clean
        }
        log.error("VM '\(vm)' failed scrub validation — destroying")
        try await node.stop(vm: vm, on: endpoint)
        try await node.delete(vm: vm, on: endpoint)
        return .destroyed
    }
}
