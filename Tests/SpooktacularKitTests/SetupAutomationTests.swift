import Testing
import Foundation
@testable import SpooktacularKit

@Suite("SetupAutomation")
struct SetupAutomationTests {

    // MARK: - Version Support

    @Test("macOS 15 (Sequoia) is supported")
    func sequoiaIsSupported() {
        #expect(SetupAutomation.isSupported(macOSVersion: 15))
    }

    @Test("macOS 26 (Tahoe) is supported")
    func tahoeIsSupported() {
        #expect(SetupAutomation.isSupported(macOSVersion: 26))
    }

    @Test(
        "Unsupported versions return false",
        arguments: [10, 11, 12, 13, 14, 16, 25, 27, 99]
    )
    func unsupportedVersions(version: Int) {
        #expect(!SetupAutomation.isSupported(macOSVersion: version))
    }

    @Test(
        "Unsupported versions return an empty sequence",
        arguments: [10, 14, 16, 99]
    )
    func unsupportedVersionsReturnEmpty(version: Int) {
        let steps = SetupAutomation.sequence(for: version)
        #expect(steps.isEmpty)
    }

    // MARK: - Sequence Existence

    @Test(
        "Supported versions return a non-empty sequence",
        arguments: [15, 26]
    )
    func supportedVersionsHaveSteps(version: Int) {
        let steps = SetupAutomation.sequence(for: version)
        #expect(!steps.isEmpty)
    }

    @Test("Sequoia sequence has a reasonable step count")
    func sequoiaStepCount() {
        let steps = SetupAutomation.sequence(for: 15)
        // The Sequoia sequence has many steps for each Setup Assistant screen.
        // It should have at least 50 steps (conservative lower bound).
        #expect(steps.count >= 50)
    }

    // MARK: - Sequence Structure

    @Test(
        "Sequence starts with a wait for VM boot",
        arguments: [15, 26]
    )
    func sequenceStartsWithWait(version: Int) {
        let steps = SetupAutomation.sequence(for: version)
        guard let first = steps.first else {
            Issue.record("Sequence is empty")
            return
        }
        // The first step should have a substantial delay (60s)
        // to wait for the VM to boot and show the Hello screen.
        #expect(first.delay >= 30)
    }

    @Test(
        "Sequence ends with SSH enablement",
        arguments: [15, 26]
    )
    func sequenceEndsWithSSH(version: Int) {
        let steps = SetupAutomation.sequence(for: version)

        // The final steps should include the SSH command and sudo password.
        // Look at the last several steps for the SSH enable command.
        let lastSteps = steps.suffix(10)
        let containsSSHCommand = lastSteps.contains { step in
            if case .text(let text) = step.action {
                return text.contains("setremotelogin")
            }
            return false
        }
        #expect(containsSSHCommand, "Sequence must end with SSH enablement")
    }

    @Test(
        "Sequence contains VoiceOver enable step (Option+F5)",
        arguments: [15, 26]
    )
    func sequenceEnablesVoiceOver(version: Int) {
        let steps = SetupAutomation.sequence(for: version)
        let hasVoiceOverToggle = steps.contains { step in
            if case .shortcut(.f5, modifiers: let mods) = step.action {
                return mods.contains(.option)
            }
            return false
        }
        #expect(hasVoiceOverToggle, "Sequence must toggle VoiceOver with Option+F5")
    }

    @Test(
        "Sequence contains VoiceOver disable step (two Option+F5 presses)",
        arguments: [15, 26]
    )
    func sequenceDisablesVoiceOver(version: Int) {
        let steps = SetupAutomation.sequence(for: version)
        let voiceOverToggles = steps.filter { step in
            if case .shortcut(.f5, modifiers: let mods) = step.action {
                return mods.contains(.option)
            }
            return false
        }
        // VoiceOver should be toggled on and then off: exactly 2 presses.
        #expect(voiceOverToggles.count == 2, "VoiceOver should be toggled on and off (2 presses)")
    }

    // MARK: - Username and Password Customization

    @Test("Default credentials use admin/admin")
    func defaultCredentials() {
        let steps = SetupAutomation.sequence(for: 15)
        let textSteps = steps.compactMap { step -> String? in
            if case .text(let text) = step.action { return text }
            return nil
        }
        // "admin" should appear multiple times: full name, account name,
        // password, verify password, and sudo password.
        let adminCount = textSteps.filter { $0 == "admin" }.count
        #expect(adminCount >= 5, "Default 'admin' should appear at least 5 times (name x2, password x2, sudo)")
    }

    @Test("Custom username appears in the sequence")
    func customUsername() {
        let steps = SetupAutomation.sequence(for: 15, username: "runner", password: "secret123")
        let textSteps = steps.compactMap { step -> String? in
            if case .text(let text) = step.action { return text }
            return nil
        }
        let runnerCount = textSteps.filter { $0 == "runner" }.count
        // Username appears as full name and account name.
        #expect(runnerCount >= 2, "Custom username 'runner' should appear at least twice")
    }

    @Test("Custom password appears in the sequence")
    func customPassword() {
        let steps = SetupAutomation.sequence(for: 15, username: "runner", password: "secret123")
        let textSteps = steps.compactMap { step -> String? in
            if case .text(let text) = step.action { return text }
            return nil
        }
        let secretCount = textSteps.filter { $0 == "secret123" }.count
        // Password appears as password, verify password, and sudo password.
        #expect(secretCount >= 3, "Custom password 'secret123' should appear at least 3 times (password, verify, sudo)")
    }

    @Test("Custom credentials do not contain the default 'admin'")
    func customCredentialsReplaceDefaults() {
        let steps = SetupAutomation.sequence(for: 15, username: "ci", password: "build")
        let textSteps = steps.compactMap { step -> String? in
            if case .text(let text) = step.action { return text }
            return nil
        }
        // No step should contain the literal "admin" when custom credentials are used.
        let hasAdmin = textSteps.contains { $0 == "admin" }
        #expect(!hasAdmin, "Custom credentials should fully replace 'admin'")
    }

    // MARK: - Boot Action Types

    @Test("All KeyCode cases have stable raw values")
    func keyCodeRawValues() {
        #expect(KeyCode.returnKey.rawValue == "returnKey")
        #expect(KeyCode.tab.rawValue == "tab")
        #expect(KeyCode.space.rawValue == "space")
        #expect(KeyCode.escape.rawValue == "escape")
        #expect(KeyCode.delete.rawValue == "delete")
        #expect(KeyCode.leftArrow.rawValue == "leftArrow")
        #expect(KeyCode.rightArrow.rawValue == "rightArrow")
        #expect(KeyCode.upArrow.rawValue == "upArrow")
        #expect(KeyCode.downArrow.rawValue == "downArrow")
        #expect(KeyCode.f5.rawValue == "f5")
    }

    @Test("All Modifier cases have stable raw values")
    func modifierRawValues() {
        #expect(Modifier.command.rawValue == "command")
        #expect(Modifier.option.rawValue == "option")
        #expect(Modifier.shift.rawValue == "shift")
        #expect(Modifier.control.rawValue == "control")
    }

    @Test("BootStep equality works correctly")
    func bootStepEquality() {
        let a = BootStep(delay: 10, action: .text("hello"))
        let b = BootStep(delay: 10, action: .text("hello"))
        let c = BootStep(delay: 5, action: .text("hello"))
        let d = BootStep(delay: 10, action: .text("world"))

        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("BootAction equality works for all variants")
    func bootActionEquality() {
        #expect(BootAction.text("a") == BootAction.text("a"))
        #expect(BootAction.text("a") != BootAction.text("b"))
        #expect(BootAction.key(.tab) == BootAction.key(.tab))
        #expect(BootAction.key(.tab) != BootAction.key(.space))
        #expect(BootAction.wait(5) == BootAction.wait(5))
        #expect(BootAction.wait(5) != BootAction.wait(10))

        let shortcutA = BootAction.shortcut(.f5, modifiers: [.option])
        let shortcutB = BootAction.shortcut(.f5, modifiers: [.option])
        let shortcutC = BootAction.shortcut(.f5, modifiers: [.command])
        #expect(shortcutA == shortcutB)
        #expect(shortcutA != shortcutC)
    }

    // MARK: - Supported Versions Set

    @Test("supportedVersions contains exactly 15 and 26")
    func supportedVersionsSet() {
        #expect(SetupAutomation.supportedVersions == [15, 26])
    }

    // MARK: - Sequence Content Validation

    @Test("Sequence opens Terminal via Spotlight")
    func sequenceOpensTerminal() {
        let steps = SetupAutomation.sequence(for: 15)
        let hasSpotlight = steps.contains { step in
            if case .shortcut(.space, modifiers: let mods) = step.action {
                return mods.contains(.option)
            }
            return false
        }
        let hasTerminalText = steps.contains { step in
            if case .text(let text) = step.action {
                return text == "Terminal"
            }
            return false
        }
        #expect(hasSpotlight, "Sequence must open Spotlight with Option+Space")
        #expect(hasTerminalText, "Sequence must type 'Terminal' to find the app")
    }

    @Test("Sequence selects English language")
    func sequenceSelectsEnglish() {
        let steps = SetupAutomation.sequence(for: 15)
        let hasEnglish = steps.contains { step in
            if case .text(let text) = step.action {
                return text == "english"
            }
            return false
        }
        #expect(hasEnglish, "Sequence must select English language")
    }

    @Test("Sequence sets timezone to UTC")
    func sequenceSetsUTC() {
        let steps = SetupAutomation.sequence(for: 15)
        let hasUTC = steps.contains { step in
            if case .text(let text) = step.action {
                return text == "UTC"
            }
            return false
        }
        #expect(hasUTC, "Sequence must set timezone to UTC")
    }
}
