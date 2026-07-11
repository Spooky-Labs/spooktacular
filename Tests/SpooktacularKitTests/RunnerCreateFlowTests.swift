import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("RunnerCreateFlowPlan")
struct RunnerCreateFlowPlanTests {

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

    // MARK: - --no-provision compatibility

    @Test("--no-provision absent passes")
    func noProvisionAbsentPasses() throws {
        try RunnerCreateFlowPlan.validateNoProvisionCompatibility(noProvision: false)
    }

    @Test("--no-provision with --github-runner is a hard error")
    func noProvisionBlocked() {
        #expect(throws: RunnerCreateFlowError.noProvisionIncompatible) {
            try RunnerCreateFlowPlan.validateNoProvisionCompatibility(noProvision: true)
        }
    }

    @Test("noProvisionIncompatible error names --github-runner and --no-provision, has recovery text")
    func noProvisionErrorText() {
        let error = RunnerCreateFlowError.noProvisionIncompatible
        #expect(error.errorDescription?.contains("--no-provision") == true)
        #expect(error.errorDescription?.contains("--github-runner") == true)
        #expect(error.recoverySuggestion != nil)
    }
}
