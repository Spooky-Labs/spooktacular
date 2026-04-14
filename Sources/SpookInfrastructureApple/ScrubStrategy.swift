import Foundation
import SpookCore
import SpookApplication

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
}
