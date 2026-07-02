import Foundation

/// Decides whether the zero-touch `--github-runner` create flow may
/// proceed given `--skip-setup` / `--no-start`, and whether the VM
/// should be started (and polled for the runner coming online)
/// once the runner script is injected.
///
/// Extracted out of `Create.swift`'s `run()` as a small pure
/// function so the skip-setup/no-start interaction is unit
/// testable without driving the full `ParsableCommand`.
///
/// ## Why `--skip-setup` conflicts with `--github-runner`
///
/// Zero-touch runner registration depends on the Spooktacular
/// Provisioner LaunchDaemon inside the guest, which is only ever
/// installed by ``SetupAutomation`` automation (see
/// `SetupAutomation.installProvisionerSteps(password:)`). Passing
/// `--skip-setup` skips that automation entirely, so an injected
/// runner script would sit on the provisioning share with nothing
/// to ever execute it — a silent dead end. `--no-start` is the
/// documented advanced escape hatch: it tells the planner the
/// operator already knows this and intends to boot + register the
/// runner by hand.
public enum RunnerCreateFlowPlan {

    /// Validates the flag combination and decides whether to
    /// auto-start the VM after the runner script is injected.
    ///
    /// - Parameters:
    ///   - skipSetup: Whether `--skip-setup` was passed.
    ///   - noStart: Whether `--no-start` was passed.
    /// - Returns: `true` if the VM should be started headless and
    ///   polled for the runner coming online after injection;
    ///   `false` if the operator opted out via `--no-start`.
    /// - Throws: ``RunnerCreateFlowError/zeroTouchRequiresSetupAutomation``
    ///   when `--skip-setup` is combined with `--github-runner`
    ///   without also passing `--no-start`.
    public static func autoStartDecision(
        skipSetup: Bool,
        noStart: Bool
    ) throws -> Bool {
        if skipSetup && !noStart {
            throw RunnerCreateFlowError.zeroTouchRequiresSetupAutomation
        }
        return !noStart
    }

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
}

/// Errors surfaced by ``RunnerCreateFlowPlan``.
public enum RunnerCreateFlowError: Error, LocalizedError, Sendable, Equatable {
    /// `--skip-setup` was combined with `--github-runner` without
    /// the `--no-start` escape hatch.
    case zeroTouchRequiresSetupAutomation

    /// `--github-runner` was combined with another flag that
    /// produces a first-boot script (`flag` names it) — both would
    /// write the same `first-boot.sh` and the last write silently
    /// wins.
    case conflictingTemplate(flag: String)

    public var errorDescription: String? {
        switch self {
        case .zeroTouchRequiresSetupAutomation:
            return "--github-runner with --skip-setup has nothing to execute the injected runner "
                + "script — zero-touch registration requires Setup Assistant automation."
        case .conflictingTemplate(let flag):
            return "--github-runner cannot be combined with \(flag): both produce a first-boot "
                + "script and they would silently overwrite each other."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .zeroTouchRequiresSetupAutomation:
            return "Drop --skip-setup so Setup Assistant automation installs the provisioner, "
                + "or add --no-start to confirm you'll boot and register the runner by hand."
        case .conflictingTemplate(let flag):
            return "Drop \(flag), or create a separate VM for it — each VM runs exactly one "
                + "first-boot provisioning script."
        }
    }
}
