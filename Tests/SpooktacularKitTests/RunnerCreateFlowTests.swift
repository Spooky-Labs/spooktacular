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
}
