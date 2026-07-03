import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("RunnerCreateFlowPlan")
struct RunnerCreateFlowPlanTests {

    @Test("normal zero-touch: auto-starts")
    func normalZeroTouch() throws {
        let autoStart = try RunnerCreateFlowPlan.autoStartDecision(skipSetup: false, noStart: false)
        #expect(autoStart == true)
    }

    @Test("--no-start alone: skips auto-start, no error")
    func noStartAlone() throws {
        let autoStart = try RunnerCreateFlowPlan.autoStartDecision(skipSetup: false, noStart: true)
        #expect(autoStart == false)
    }

    @Test("--skip-setup without --no-start: hard error")
    func skipSetupBlocked() {
        #expect(throws: RunnerCreateFlowError.zeroTouchRequiresSetupAutomation) {
            _ = try RunnerCreateFlowPlan.autoStartDecision(skipSetup: true, noStart: false)
        }
    }

    @Test("--skip-setup + --no-start: advanced escape hatch allowed, auto-start off")
    func skipSetupWithNoStart() throws {
        let autoStart = try RunnerCreateFlowPlan.autoStartDecision(skipSetup: true, noStart: true)
        #expect(autoStart == false)
    }

    @Test("error has description and recovery suggestion")
    func errorText() {
        let error = RunnerCreateFlowError.zeroTouchRequiresSetupAutomation
        #expect(error.errorDescription != nil)
        #expect(error.recoverySuggestion != nil)
    }

    // MARK: - Template exclusivity

    @Test("no conflicting template flags passes")
    func exclusivityClean() throws {
        try RunnerCreateFlowPlan.validateTemplateExclusivity(
            remoteDesktop: false, openclaw: false, hasUserData: false
        )
    }

    @Test("--remote-desktop conflicts with --github-runner")
    func exclusivityRemoteDesktop() {
        #expect(throws: RunnerCreateFlowError.conflictingTemplate(flag: "--remote-desktop")) {
            try RunnerCreateFlowPlan.validateTemplateExclusivity(
                remoteDesktop: true, openclaw: false, hasUserData: false
            )
        }
    }

    @Test("--openclaw conflicts with --github-runner")
    func exclusivityOpenclaw() {
        #expect(throws: RunnerCreateFlowError.conflictingTemplate(flag: "--openclaw")) {
            try RunnerCreateFlowPlan.validateTemplateExclusivity(
                remoteDesktop: false, openclaw: true, hasUserData: false
            )
        }
    }

    @Test("--user-data conflicts with --github-runner")
    func exclusivityUserData() {
        #expect(throws: RunnerCreateFlowError.conflictingTemplate(flag: "--user-data")) {
            try RunnerCreateFlowPlan.validateTemplateExclusivity(
                remoteDesktop: false, openclaw: false, hasUserData: true
            )
        }
    }

    @Test("conflictingTemplate error names the flag and has recovery text")
    func conflictErrorText() {
        let error = RunnerCreateFlowError.conflictingTemplate(flag: "--remote-desktop")
        #expect(error.errorDescription?.contains("--remote-desktop") == true)
        #expect(error.recoverySuggestion != nil)
    }

    // MARK: - Provision mode

    @Test("disk-inject provision mode passes")
    func provisionModeDiskInject() throws {
        try RunnerCreateFlowPlan.validateProvisionMode(isDiskInject: true)
    }

    @Test("non-disk-inject provision mode is a hard error")
    func provisionModeOther() {
        #expect(throws: RunnerCreateFlowError.unsupportedProvisionMode) {
            try RunnerCreateFlowPlan.validateProvisionMode(isDiskInject: false)
        }
    }

    @Test("unsupportedProvisionMode error has description and recovery text")
    func provisionModeErrorText() {
        let error = RunnerCreateFlowError.unsupportedProvisionMode
        #expect(error.errorDescription?.contains("disk-inject") == true)
        #expect(error.recoverySuggestion != nil)
    }

    // MARK: - Setup automation failure fatality

    @Test("--github-runner: a Setup Assistant automation failure is fatal")
    func setupAutomationFailureFatalUnderRunner() {
        let isFatal = RunnerCreateFlowPlan.setupAutomationFailureIsFatal(githubRunner: true)
        #expect(isFatal == true)
    }

    @Test("no --github-runner: a Setup Assistant automation failure is swallowed")
    func setupAutomationFailureSwallowedWithoutRunner() {
        let isFatal = RunnerCreateFlowPlan.setupAutomationFailureIsFatal(githubRunner: false)
        #expect(isFatal == false)
    }

    // MARK: - macOS version support

    @Test("--github-runner with a supported macOS major passes", arguments: [15, 26])
    func macOSVersionSupportedPasses(major: Int) throws {
        try RunnerCreateFlowPlan.validateMacOSVersionSupport(
            githubRunner: true,
            macOSMajorVersion: major
        )
    }

    @Test("--github-runner with an unsupported macOS major is a hard error")
    func macOSVersionUnsupportedFails() {
        #expect(throws: RunnerCreateFlowError.unsupportedMacOSVersion(
            macOSMajorVersion: 14,
            supportedVersions: SetupAutomation.supportedVersions
        )) {
            try RunnerCreateFlowPlan.validateMacOSVersionSupport(
                githubRunner: true,
                macOSMajorVersion: 14
            )
        }
    }

    @Test("--github-runner with a future unsupported macOS major is also a hard error")
    func macOSVersionFutureUnsupportedFails() {
        #expect(throws: RunnerCreateFlowError.unsupportedMacOSVersion(
            macOSMajorVersion: 27,
            supportedVersions: SetupAutomation.supportedVersions
        )) {
            try RunnerCreateFlowPlan.validateMacOSVersionSupport(
                githubRunner: true,
                macOSMajorVersion: 27
            )
        }
    }

    @Test("without --github-runner, an unsupported macOS major is not validated at all")
    func macOSVersionSkippedWithoutRunner() throws {
        // A plain desktop create with no --github-runner has no
        // dependency on Setup Assistant automation succeeding —
        // it's fine to boot into an unsupported macOS version and
        // finish setup by hand.
        try RunnerCreateFlowPlan.validateMacOSVersionSupport(
            githubRunner: false,
            macOSMajorVersion: 14
        )
    }

    @Test("unsupportedMacOSVersion error names every supported major and has recovery text")
    func macOSVersionErrorText() {
        let error = RunnerCreateFlowError.unsupportedMacOSVersion(
            macOSMajorVersion: 14,
            supportedVersions: [15, 26]
        )
        #expect(error.errorDescription?.contains("14") == true)
        #expect(error.errorDescription?.contains("15") == true)
        #expect(error.errorDescription?.contains("26") == true)
        #expect(error.recoverySuggestion?.contains("15") == true)
        #expect(error.recoverySuggestion?.contains("26") == true)
    }

    // MARK: - First-boot provisioning plan (any script source — GUI + CLI)

    @Test(
        "no first-boot script: no plan regardless of macOS version",
        arguments: [14, 15, 26, 27]
    )
    func firstBootPlanNoScript(major: Int) {
        let plan = RunnerCreateFlowPlan.firstBootProvisioningPlan(
            hasFirstBootScript: false,
            macOSMajorVersion: major
        )
        #expect(plan == .noScript)
    }

    @Test(
        "first-boot script on a supported macOS major: stage provisioner + automate",
        arguments: [15, 26]
    )
    func firstBootPlanSupported(major: Int) {
        let plan = RunnerCreateFlowPlan.firstBootProvisioningPlan(
            hasFirstBootScript: true,
            macOSMajorVersion: major
        )
        #expect(plan == .stageProvisionerAndAutomate)
    }

    @Test("first-boot script on an unsupported macOS major: names the version instead of silently no-op'ing")
    func firstBootPlanUnsupported() {
        let plan = RunnerCreateFlowPlan.firstBootProvisioningPlan(
            hasFirstBootScript: true,
            macOSMajorVersion: 14
        )
        #expect(plan == .unsupportedMacOSVersion(14))
    }

    @Test("first-boot script on a future unsupported macOS major also names the version")
    func firstBootPlanFutureUnsupported() {
        let plan = RunnerCreateFlowPlan.firstBootProvisioningPlan(
            hasFirstBootScript: true,
            macOSMajorVersion: 27
        )
        #expect(plan == .unsupportedMacOSVersion(27))
    }
}
