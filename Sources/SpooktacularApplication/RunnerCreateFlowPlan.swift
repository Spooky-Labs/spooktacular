import Foundation

/// Validates the `--github-runner` create flow's flag combinations.
///
/// Extracted out of `Create.swift`'s `run()` as small pure functions
/// so these checks are unit testable without driving the full
/// `ParsableCommand`.
public enum RunnerCreateFlowPlan {

    /// Rejects `--github-runner` combined with any other flag that
    /// produces a first-boot provisioning script.
    ///
    /// All first-boot scripts land at the same fixed destination in
    /// the VM bundle's provisioning share (`first-boot.sh` —
    /// `DiskInjector` documents "last write wins"), and the runner
    /// script is injected LAST, after the create flow's success
    /// summary. Allowing the combination would silently discard the
    /// other template's script right after the console printed that
    /// it was injected. Before the create-flow reorder these flags
    /// were mutually exclusive by `else if` ordering (the runner
    /// branch simply won, silently); a hard error is strictly more
    /// honest than either silent behavior.
    ///
    /// - Parameters:
    ///   - remoteDesktop: Whether `--remote-desktop` was passed.
    ///   - openclaw: Whether `--openclaw` was passed.
    ///   - hasUserData: Whether `--user-data <path>` was passed.
    /// - Throws: ``RunnerCreateFlowError/conflictingTemplate(flag:)``
    ///   naming the first conflicting flag found.
    public static func validateTemplateExclusivity(
        remoteDesktop: Bool,
        openclaw: Bool,
        hasUserData: Bool
    ) throws {
        if remoteDesktop {
            throw RunnerCreateFlowError.conflictingTemplate(flag: "--remote-desktop")
        }
        if openclaw {
            throw RunnerCreateFlowError.conflictingTemplate(flag: "--openclaw")
        }
        if hasUserData {
            throw RunnerCreateFlowError.conflictingTemplate(flag: "--user-data")
        }
    }

    /// Rejects `--github-runner` with any `--provision` mode other
    /// than disk-inject.
    ///
    /// The runner script is executed by the Spooktacular Provisioner
    /// LaunchDaemon, which only consumes disk-injected
    /// `first-boot.sh` scripts from the provisioning share. With
    /// `--provision ssh` or `--provision shared-folder` the create
    /// flow would skip staging the provisioner pkg (only the
    /// disk-inject path stages it) while the runner branch still
    /// disk-injects its script — leaving a script on the share that
    /// nothing ever executes, i.e. a guaranteed, undiagnosable
    /// online-poll timeout.
    ///
    /// - Parameter isDiskInject: Whether the effective provisioning
    ///   mode is disk-inject (the default).
    /// - Throws: ``RunnerCreateFlowError/unsupportedProvisionMode``
    ///   for any other mode.
    public static func validateProvisionMode(isDiskInject: Bool) throws {
        guard isDiskInject else {
            throw RunnerCreateFlowError.unsupportedProvisionMode
        }
    }

    /// Rejects `--github-runner` combined with `--no-provision`.
    ///
    /// `--no-provision` promises the generated first-boot script is
    /// left on disk, unexecuted, for the operator to run later by
    /// hand (see `Create.swift`'s `noProvision` help text). But the
    /// runner flow's zero-touch registration has no "run it later by
    /// hand" mode: `provisionGitHubRunner` unconditionally mints a
    /// one-hour registration token, disk-injects the runner script,
    /// and (unless `--no-start`) boots the VM and polls GitHub for
    /// the runner coming online — `noProvision` is never consulted
    /// on that path. Letting the combination through would silently
    /// ignore the flag while a live, single-use registration token
    /// gets minted and burned into a script that either executes
    /// anyway (contradicting "not executed") or — if the operator
    /// expected the documented skip and boots much later by hand —
    /// executes against an already-expired token. Failing fast here
    /// is strictly more honest than either outcome.
    ///
    /// - Parameter noProvision: Whether `--no-provision` was passed.
    /// - Throws: ``RunnerCreateFlowError/noProvisionIncompatible``
    ///   when `--no-provision` is combined with `--github-runner`.
    public static func validateNoProvisionCompatibility(noProvision: Bool) throws {
        guard !noProvision else {
            throw RunnerCreateFlowError.noProvisionIncompatible
        }
    }

}

/// Errors surfaced by ``RunnerCreateFlowPlan``.
public enum RunnerCreateFlowError: Error, LocalizedError, Sendable, Equatable {
    /// `--github-runner` was combined with another flag that
    /// produces a first-boot script (`flag` names it) — both would
    /// write the same `first-boot.sh` and the last write silently
    /// wins.
    case conflictingTemplate(flag: String)

    /// `--github-runner` was combined with a `--provision` mode
    /// other than disk-inject — the provisioner daemon that executes
    /// the runner script only consumes disk-injected scripts.
    case unsupportedProvisionMode

    /// `--github-runner` was combined with `--no-provision` — the
    /// runner script must execute on first boot for zero-touch
    /// registration to work, so "generated but not executed" is
    /// never a valid outcome for this flow.
    case noProvisionIncompatible

    public var errorDescription: String? {
        switch self {
        case .conflictingTemplate(let flag):
            return "--github-runner cannot be combined with \(flag): both produce a first-boot "
                + "script and they would silently overwrite each other."
        case .unsupportedProvisionMode:
            return "--github-runner only supports --provision disk-inject: the runner script is "
                + "executed by the provisioner LaunchDaemon on first boot, which only consumes "
                + "disk-injected scripts."
        case .noProvisionIncompatible:
            return "--no-provision is incompatible with --github-runner because the runner "
                + "requires the injected first-boot script to execute."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .conflictingTemplate(let flag):
            return "Drop \(flag), or create a separate VM for it — each VM runs exactly one "
                + "first-boot provisioning script."
        case .unsupportedProvisionMode:
            return "Drop the --provision flag — disk-inject is the default and the only mode "
                + "the runner flow supports."
        case .noProvisionIncompatible:
            return "Drop --no-provision. If you need manual control over provisioning, drop "
                + "--github-runner too and inject the runner script yourself later via "
                + "spook start --user-data <path>."
        }
    }
}
