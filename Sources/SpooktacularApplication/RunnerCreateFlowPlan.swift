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

    /// Decides whether a Setup Assistant automation failure must
    /// abort the create flow rather than being swallowed so a
    /// desktop VM can still be used with setup finished by hand.
    ///
    /// Zero-touch runner registration depends on the Spooktacular
    /// Provisioner LaunchDaemon inside the guest, which is only
    /// ever installed by ``SetupAutomation`` automation (see
    /// `SetupAutomation.installProvisionerSteps(password:)`). If
    /// that automation fails under `--github-runner`, the
    /// provisioner never lands, so the runner script that's about
    /// to be disk-injected would sit on the provisioning share with
    /// nothing to ever execute it — a guaranteed ~10-minute online
    /// poll timeout with no actionable diagnostic. Failing fast
    /// instead — before minting a registration token, injecting the
    /// script, or booting — surfaces the real failure immediately
    /// and keeps the (fully macOS-installed) VM bundle so the
    /// operator can finish Setup Assistant by hand.
    ///
    /// For a plain desktop create (no `--github-runner`), nothing
    /// downstream depends on the provisioner, so a failed automation
    /// is safe to swallow: the VM is still a perfectly usable
    /// desktop VM once the operator completes Setup Assistant
    /// manually via `spook start`.
    ///
    /// - Parameter githubRunner: Whether `--github-runner` was
    ///   passed to `create`.
    /// - Returns: `true` when a Setup Assistant automation failure
    ///   must abort the create flow instead of being swallowed.
    public static func setupAutomationFailureIsFatal(githubRunner: Bool) -> Bool {
        githubRunner
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

    /// `--github-runner` was combined with a `--provision` mode
    /// other than disk-inject — the provisioner daemon that executes
    /// the runner script only consumes disk-injected scripts.
    case unsupportedProvisionMode

    public var errorDescription: String? {
        switch self {
        case .zeroTouchRequiresSetupAutomation:
            return "--github-runner with --skip-setup has nothing to execute the injected runner "
                + "script — zero-touch registration requires Setup Assistant automation."
        case .conflictingTemplate(let flag):
            return "--github-runner cannot be combined with \(flag): both produce a first-boot "
                + "script and they would silently overwrite each other."
        case .unsupportedProvisionMode:
            return "--github-runner only supports --provision disk-inject: the runner script is "
                + "executed by the provisioner LaunchDaemon on first boot, which only consumes "
                + "disk-injected scripts."
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
        case .unsupportedProvisionMode:
            return "Drop the --provision flag — disk-inject is the default and the only mode "
                + "the runner flow supports."
        }
    }
}
