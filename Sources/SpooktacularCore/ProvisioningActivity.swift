import Foundation

/// A point-in-time snapshot of a VM's first-boot provisioning
/// state. Computed by
/// ``SpooktacularInfrastructureApple/VirtualMachineBundle/readProvisioningActivity()``
/// from the on-disk contents of the bundle's `provision/`
/// directory.
///
/// The model is intentionally flat: exactly one script can be
/// pending at a time (`first-boot.sh`), and at most one
/// previous run is tracked (its logs and exit code, overwritten
/// by the next run). That matches the single-shot first-boot
/// semantics of `RunAtLoad=true` without a queue — injecting a
/// new script replaces the pending one; the daemon's next
/// boot executes it and updates the last-run summary.
public struct ProvisioningActivity: Sendable, Equatable {

    /// `true` when `first-boot.sh` exists in the bundle's
    /// `provision/` directory — the host has queued a script
    /// and the guest daemon hasn't consumed it yet.
    public let scriptPending: Bool

    /// Mtime of the pending script, if one exists. `nil` when
    /// ``scriptPending`` is `false`.
    public let scriptPendingSince: Date?

    /// Summary of the most recent completed run, if any. `nil`
    /// until the daemon writes an `exit-code` file for the
    /// first time on this bundle.
    public let lastRun: Run?

    public init(
        scriptPending: Bool,
        scriptPendingSince: Date? = nil,
        lastRun: Run? = nil
    ) {
        self.scriptPending = scriptPending
        self.scriptPendingSince = scriptPendingSince
        self.lastRun = lastRun
    }

    /// Record of a first-boot script the daemon ran to
    /// completion. A single slot per bundle — the next run
    /// overwrites this one.
    public struct Run: Sendable, Equatable {

        /// When the daemon finished running this script.
        /// Derived from the mtime of the `first-boot.exit-code`
        /// file, which the daemon writes last.
        public let completedAt: Date

        /// The script's exit status. `0` means success. Non-
        /// zero values preserve the original exit code so the
        /// UI can distinguish "user script failed" from
        /// "daemon couldn't parse the exit file at all" (−1).
        public let exitCode: Int

        /// Byte size of `first-boot.stdout.log`. Used to decide
        /// whether the UI bothers offering an "open output"
        /// action.
        public let stdoutBytes: Int

        /// Byte size of `first-boot.stderr.log`. Same purpose.
        public let stderrBytes: Int

        /// Convenience: `true` iff the script exited zero.
        public var succeeded: Bool { exitCode == 0 }

        public init(
            completedAt: Date,
            exitCode: Int,
            stdoutBytes: Int,
            stderrBytes: Int
        ) {
            self.completedAt = completedAt
            self.exitCode = exitCode
            self.stdoutBytes = stdoutBytes
            self.stderrBytes = stderrBytes
        }
    }
}
