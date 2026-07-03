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

    /// Rejects `--github-runner` when the resolved restore image's
    /// macOS major version has no ``SetupAutomation`` sequence.
    ///
    /// Zero-touch runner registration depends on Setup Assistant
    /// automation to install the Spooktacular Provisioner
    /// LaunchDaemon (see ``setupAutomationFailureIsFatal(githubRunner:)``'s
    /// doc comment for the full dependency chain). When
    /// ``SetupAutomation/isSupported(macOSVersion:)`` is `false` for
    /// the version this create is about to install — a macOS major
    /// that predates the mapped sequences, or a future major that
    /// hasn't been mapped yet — there is no automation to run at
    /// all, so `setupAutomationFailureIsFatal` never gets a chance
    /// to fire: the create flow would silently skip straight to
    /// "no automated Setup Assistant sequence, complete setup
    /// manually" and then still mint a token, inject the runner
    /// script, boot headless, and poll for up to 10 minutes for a
    /// runner that can never come online. Calling this BEFORE the
    /// IPSW install begins (not just before minting) means an
    /// operator who passes an unsupported `--from-ipsw` gets an
    /// immediate, actionable error instead of losing 10-20 minutes
    /// to an install whose runner phase was always going to fail.
    ///
    /// - Parameters:
    ///   - githubRunner: Whether `--github-runner` was passed.
    ///   - macOSMajorVersion: The resolved restore image's major
    ///     version (`VZMacOSRestoreImage.operatingSystemVersion.majorVersion`).
    /// - Throws: ``RunnerCreateFlowError/unsupportedMacOSVersion(macOSMajorVersion:supportedVersions:)``
    ///   naming every supported major so the operator knows exactly
    ///   which restore image to use instead.
    public static func validateMacOSVersionSupport(
        githubRunner: Bool,
        macOSMajorVersion: Int
    ) throws {
        guard githubRunner else { return }
        guard SetupAutomation.isSupported(macOSVersion: macOSMajorVersion) else {
            throw RunnerCreateFlowError.unsupportedMacOSVersion(
                macOSMajorVersion: macOSMajorVersion,
                supportedVersions: SetupAutomation.supportedVersions
            )
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

    /// Decides what a macOS create with a first-boot script should
    /// do about staging the Spooktacular Provisioner and running
    /// Setup Assistant automation — for ANY first-boot script
    /// source, not just `--github-runner`.
    ///
    /// Every first-boot script (GitHub runner, `--remote-desktop`,
    /// `--openclaw`, `--user-data`) lands at the same fixed
    /// destination in the VM bundle's provisioning share
    /// (`first-boot.sh`, "last write wins" — see
    /// ``validateTemplateExclusivity(remoteDesktop:openclaw:hasUserData:)``),
    /// and is only ever executed by the guest's Spooktacular
    /// Provisioner LaunchDaemon — which itself is only ever
    /// installed by ``SetupAutomation`` automation (see
    /// `SetupAutomation.installProvisionerSteps(password:)`). A
    /// script with nothing to run it is a silent dead end that
    /// looks identical to a script that ran and did nothing; this
    /// decision exists so callers can tell the difference and warn
    /// instead of silently no-op'ing — see
    /// ``FirstBootProvisioningPlan/unsupportedMacOSVersion(_:)``.
    ///
    /// Mirrors `Create.swift`'s `willInjectFirstBootScript` check
    /// (`provision == .diskInject && (githubRunner || remoteDesktop
    /// || openclaw || userData != nil)`), generalized: that gate
    /// only fires when a first-boot script is actually about to be
    /// disk-injected — not, say, a plain Guest Tools install with
    /// no script at all — so `hasFirstBootScript` should be `true`
    /// only when the caller is about to call
    /// `DiskInjector.inject(script:into:)`.
    ///
    /// - Parameters:
    ///   - hasFirstBootScript: Whether a first-boot script (runner,
    ///     template-generated, or `--user-data`/operator-supplied)
    ///     is about to be disk-injected.
    ///   - macOSMajorVersion: The macOS major version the VM was
    ///     just installed with.
    /// - Returns: The plan the caller should follow.
    public static func firstBootProvisioningPlan(
        hasFirstBootScript: Bool,
        macOSMajorVersion: Int
    ) -> FirstBootProvisioningPlan {
        guard hasFirstBootScript else { return .noScript }
        guard SetupAutomation.isSupported(macOSVersion: macOSMajorVersion) else {
            return .unsupportedMacOSVersion(macOSMajorVersion)
        }
        return .stageProvisionerAndAutomate
    }
}

/// The plan returned by
/// ``RunnerCreateFlowPlan/firstBootProvisioningPlan(hasFirstBootScript:macOSMajorVersion:)``.
public enum FirstBootProvisioningPlan: Equatable, Sendable {
    /// No first-boot script is being injected — nothing to stage.
    case noScript

    /// Stage `Spooktacular Provisioner.pkg` into the bundle's
    /// provisioning share and run Setup Assistant automation
    /// (with `installProvisioner: true`) before injecting the
    /// script, so the guest's provisioner LaunchDaemon is in place
    /// to execute it on first boot.
    case stageProvisionerAndAutomate

    /// A first-boot script is being injected, but this macOS major
    /// has no ``SetupAutomation`` sequence at all — there is no
    /// automation to run, so nothing will install the provisioner
    /// LaunchDaemon. The script should still be injected (it may
    /// be useful later), but the caller MUST surface this to the
    /// operator rather than silently no-op'ing: the script will
    /// not run until Setup Assistant is completed by hand and the
    /// provisioner package is installed manually.
    case unsupportedMacOSVersion(Int)
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

    /// `--github-runner` was combined with a restore image whose
    /// macOS major version has no ``SetupAutomation`` sequence —
    /// there is nothing to install the provisioner LaunchDaemon,
    /// so the runner could never come online.
    case unsupportedMacOSVersion(macOSMajorVersion: Int, supportedVersions: Set<Int>)

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
        case .unsupportedMacOSVersion(let macOSMajorVersion, let supportedVersions):
            let supported = supportedVersions.sorted().map(String.init).joined(separator: ", ")
            return "--github-runner requires a macOS version with a Setup Assistant automation "
                + "sequence. macOS \(macOSMajorVersion) has none — supported majors: \(supported)."
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
        case .unsupportedMacOSVersion(_, let supportedVersions):
            let supported = supportedVersions.sorted().map { "macOS \($0)" }.joined(separator: " or ")
            return "Use --from-ipsw with a \(supported) restore image, or drop --github-runner "
                + "and complete Setup Assistant + provisioner install manually."
        }
    }
}
