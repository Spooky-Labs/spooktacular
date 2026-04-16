import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("SetupAutomation", .tags(.configuration))
struct SetupAutomationTests {

    // MARK: - Version Support

    @Suite("Version support", .tags(.configuration))
    struct VersionSupportTests {

        @Test("supportedVersions contains exactly 15 and 26")
        func supportedVersionsSet() {
            #expect(SetupAutomation.supportedVersions == [15, 26])
        }

        @Test(
            "Supported versions return true and produce a non-empty sequence",
            arguments: [15, 26]
        )
        func supportedVersions(version: Int) {
            #expect(SetupAutomation.isSupported(macOSVersion: version))
            let steps = SetupAutomation.sequence(for: version)
            #expect(!steps.isEmpty)
        }

        @Test(
            "Unsupported versions return false and produce an empty sequence",
            arguments: [10, 11, 12, 13, 14, 16, 25, 27, 99]
        )
        func unsupportedVersions(version: Int) {
            #expect(!SetupAutomation.isSupported(macOSVersion: version))
            #expect(SetupAutomation.sequence(for: version).isEmpty)
        }
    }

    // MARK: - Sequence Structure

    @Suite("Sequence structure", .tags(.configuration))
    struct SequenceStructureTests {

        @Test(
            "Sequence starts with a wait for VM boot (delay >= 30s)",
            arguments: [15, 26]
        )
        func sequenceStartsWithWait(version: Int) {
            let steps = SetupAutomation.sequence(for: version)
            let first = try! #require(steps.first, "Sequence must not be empty")
            #expect(first.delay >= 30)
        }

        @Test(
            "Sequence ends with SSH enablement",
            arguments: [15, 26]
        )
        func sequenceEndsWithSSH(version: Int) {
            let lastSteps = SetupAutomation.sequence(for: version).suffix(10)
            let containsSSHCommand = lastSteps.contains { step in
                if case .text(let text) = step.action {
                    return text.contains("setremotelogin")
                }
                return false
            }
            #expect(containsSSHCommand, "Sequence must end with SSH enablement")
        }

        @Test(
            "Sequence contains exactly 2 VoiceOver toggles (Option+F5)",
            arguments: [15, 26]
        )
        func voiceOverToggles(version: Int) {
            let steps = SetupAutomation.sequence(for: version)
            let toggles = steps.filter { step in
                if case .shortcut(.f5, modifiers: let mods) = step.action {
                    return mods.contains(.option)
                }
                return false
            }
            #expect(toggles.count == 2, "VoiceOver should be toggled on and off (2 presses)")
        }

        @Test("Sequoia sequence has at least 50 steps")
        func sequoiaStepCount() {
            let steps = SetupAutomation.sequence(for: 15)
            #expect(steps.count >= 50)
        }

        @Test("Sequence opens Terminal via Spotlight and selects English")
        func spotlightAndLanguage() {
            let steps = SetupAutomation.sequence(for: 15)
            let hasSpotlight = steps.contains { step in
                if case .shortcut(.space, modifiers: let mods) = step.action {
                    return mods.contains(.option)
                }
                return false
            }
            let hasTerminalText = steps.contains { step in
                if case .text(let text) = step.action { return text == "Terminal" }
                return false
            }
            let hasEnglish = steps.contains { step in
                if case .text(let text) = step.action { return text == "english" }
                return false
            }
            #expect(hasSpotlight, "Must open Spotlight with Option+Space")
            #expect(hasTerminalText, "Must type 'Terminal'")
            #expect(hasEnglish, "Must select English language")
        }

        @Test("Sequence sets timezone to UTC")
        func sequenceSetsUTC() {
            let steps = SetupAutomation.sequence(for: 15)
            let hasUTC = steps.contains { step in
                if case .text(let text) = step.action { return text == "UTC" }
                return false
            }
            #expect(hasUTC, "Must set timezone to UTC")
        }
    }

    // MARK: - Username and Password Customization

    @Suite("Credentials", .tags(.configuration))
    struct CredentialsTests {

        @Test("Default credentials use admin/admin (at least 5 occurrences)")
        func defaultCredentials() {
            let steps = SetupAutomation.sequence(for: 15)
            let textSteps = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            let adminCount = textSteps.filter { $0 == "admin" }.count
            #expect(
                adminCount >= 5,
                "Default 'admin' should appear at least 5 times (name x2, password x2, sudo)"
            )
        }

        @Test("Custom username appears at least twice in the sequence")
        func customUsername() {
            let steps = SetupAutomation.sequence(for: 15, username: "runner", password: "secret123")
            let textSteps = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            let runnerCount = textSteps.filter { $0 == "runner" }.count
            #expect(runnerCount >= 2, "Custom username 'runner' should appear at least twice")
        }

        @Test("Custom password appears at least 3 times in the sequence")
        func customPassword() {
            let steps = SetupAutomation.sequence(for: 15, username: "runner", password: "secret123")
            let textSteps = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            let secretCount = textSteps.filter { $0 == "secret123" }.count
            #expect(
                secretCount >= 3,
                "Custom password 'secret123' should appear at least 3 times (password, verify, sudo)"
            )
        }

        @Test("Custom credentials fully replace 'admin'")
        func customCredentialsReplaceDefaults() {
            let steps = SetupAutomation.sequence(for: 15, username: "ci", password: "build")
            let textSteps = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            let hasAdmin = textSteps.contains { $0 == "admin" }
            #expect(!hasAdmin, "Custom credentials should fully replace 'admin'")
        }
    }

    // MARK: - Boot Action Types

    @Suite("Boot action types", .tags(.configuration))
    struct BootActionTypeTests {

        @Test(
            "KeyCode raw values are stable",
            arguments: [
                (KeyCode.returnKey, "returnKey"),
                (.tab, "tab"),
                (.space, "space"),
                (.escape, "escape"),
                (.delete, "delete"),
                (.leftArrow, "leftArrow"),
                (.rightArrow, "rightArrow"),
                (.upArrow, "upArrow"),
                (.downArrow, "downArrow"),
                (.f5, "f5"),
            ]
        )
        func keyCodeRawValues(keyCode: KeyCode, expected: String) {
            #expect(keyCode.rawValue == expected)
        }

        @Test(
            "Modifier raw values are stable",
            arguments: [
                (Modifier.command, "command"),
                (.option, "option"),
                (.shift, "shift"),
                (.control, "control"),
            ]
        )
        func modifierRawValues(modifier: Modifier, expected: String) {
            #expect(modifier.rawValue == expected)
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
    }
}
