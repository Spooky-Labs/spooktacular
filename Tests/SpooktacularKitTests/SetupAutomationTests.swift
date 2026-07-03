import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

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
        func supportedVersions(version: Int) throws {
            #expect(SetupAutomation.isSupported(macOSVersion: version))
            let steps = try SetupAutomation.sequence(for: version)
            #expect(!steps.isEmpty)
        }

        @Test(
            "Unsupported versions return false and throw with the requested + supported set",
            arguments: [10, 11, 12, 13, 14, 16, 25, 27, 99]
        )
        func unsupportedVersions(version: Int) {
            #expect(!SetupAutomation.isSupported(macOSVersion: version))
            #expect(throws: SetupAutomationError.unsupportedVersion(
                requested: version,
                supported: SetupAutomation.supportedVersions
            )) {
                _ = try SetupAutomation.sequence(for: version)
            }
        }

        @Test("Unsupported version error message names the requested major + lists supported versions")
        func unsupportedVersionErrorIsActionable() {
            let err = SetupAutomationError.unsupportedVersion(
                requested: 42,
                supported: SetupAutomation.supportedVersions
            )
            let description = try? #require(err.errorDescription)
            #expect(description?.contains("42") == true,
                    "Error must name the requested macOS version")
            for version in SetupAutomation.supportedVersions {
                #expect(description?.contains(String(version)) == true,
                        "Error must list supported version \(version)")
            }
            #expect(err.recoverySuggestion?.isEmpty == false,
                    "Error must provide an actionable recovery suggestion")
        }
    }

    // MARK: - Sequence Structure

    @Suite("Sequence structure", .tags(.configuration))
    struct SequenceStructureTests {

        @Test(
            "Sequence starts with a wait for VM boot (delay >= 30s)",
            arguments: [15, 26]
        )
        func sequenceStartsWithWait(version: Int) throws {
            let steps = try SetupAutomation.sequence(for: version)
            let first = try #require(steps.first, "Sequence must not be empty")
            #expect(first.delay >= 30)
        }

        @Test(
            "Sequence ends with SSH enablement",
            arguments: [15, 26]
        )
        func sequenceEndsWithSSH(version: Int) throws {
            let lastSteps = try SetupAutomation.sequence(for: version).suffix(10)
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
        func voiceOverToggles(version: Int) throws {
            let steps = try SetupAutomation.sequence(for: version)
            let toggles = steps.filter { step in
                if case .shortcut(.f5, modifiers: let mods) = step.action {
                    return mods.contains(.option)
                }
                return false
            }
            #expect(toggles.count == 2, "VoiceOver should be toggled on and off (2 presses)")
        }

        @Test("Sequoia sequence has at least 50 steps")
        func sequoiaStepCount() throws {
            let steps = try SetupAutomation.sequence(for: 15)
            #expect(steps.count >= 50)
        }

        @Test("Sequence opens Terminal via Spotlight and selects English")
        func spotlightAndLanguage() throws {
            let steps = try SetupAutomation.sequence(for: 15)
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
        func sequenceSetsUTC() throws {
            let steps = try SetupAutomation.sequence(for: 15)
            let hasUTC = steps.contains { step in
                if case .text(let text) = step.action { return text == "UTC" }
                return false
            }
            #expect(hasUTC, "Must set timezone to UTC")
        }

        @Test(
            "Country screen is confirmed via a screen-reader click on 'Continue', not a blind keystroke",
            arguments: [15, 26]
        )
        func countryScreenConfirmsViaClickText(version: Int) throws {
            // Regression test for live e2e gate 12/100
            // (`plans/e2e-notes-2026-07.md`, ATTEMPT 4): a blind
            // `shiftTab` + `space` confirm left "United States"
            // selected and "Continue" visibly enabled but never
            // clicked, so the next screen gate timed out. The fix
            // reads the actual screen and clicks the button instead
            // of guessing a Tab-focus chain.
            let steps = try SetupAutomation.sequence(for: version)
            let countryTextIndex = try #require(steps.firstIndex { step in
                if case .text(let text) = step.action { return text == "united states" }
                return false
            })
            let confirmAction = steps[countryTextIndex + 1].action
            guard case .clickText(let label, _) = confirmAction else {
                Issue.record("Expected the country selection to be confirmed via clickText, got \(confirmAction)")
                return
            }
            #expect(label == "Continue")
        }

        @Test(
            "Transfer Data screen selects 'Set up as new' via clickText, not a fixed Tab count",
            arguments: [15, 26]
        )
        func transferDataScreenConfirmsViaClickText(version: Int) throws {
            // Regression test for live e2e gate 25/102
            // (`plans/e2e-notes-2026-07.md`, ATTEMPT 5): a hard-coded
            // `tab, tab, tab, space` assumed a 3-row radio list and,
            // once macOS 26 grew a 4th row ("Set up with iPhone or
            // iPad" inserted above "Set up as new"), landed on and
            // selected the wrong row. The fix reads the actual screen
            // and clicks the labeled row instead of counting Tabs
            // through a list whose length Apple can change between OS
            // versions — same pattern as the country screen's
            // `clickText("Continue")` fix.
            let steps = try SetupAutomation.sequence(for: version)
            let transferGateIndex = try #require(steps.firstIndex { step in
                if case .expectScreen(let markers, _) = step.action {
                    return markers.contains("Migration Assistant") || markers.contains("Transfer Your Data")
                }
                return false
            })
            let selectAction = steps[transferGateIndex + 1].action
            guard case .clickText(let selectLabel, _) = selectAction else {
                Issue.record("Expected the Transfer Data row selection to use clickText, got \(selectAction)")
                return
            }
            #expect(selectLabel == "Set up as new")

            let confirmAction = steps[transferGateIndex + 2].action
            guard case .clickText(let confirmLabel, _) = confirmAction else {
                Issue.record("Expected the Transfer Data confirm to use clickText, got \(confirmAction)")
                return
            }
            #expect(confirmLabel == "Continue")
        }

        @Test(
            "No hard-coded multi-Tab radio navigation remains anywhere in the sequence",
            arguments: [15, 26]
        )
        func noHardCodedMultiTabRadioNavigationRemains(version: Int) throws {
            // Regression guard against reintroducing the exact defect
            // class behind both the country-screen (gate 12/100) and
            // Transfer Data (gate 25/102) live e2e failures: three or
            // more consecutive same-direction Tab presses immediately
            // followed by Space, blindly counting keystrokes to reach
            // the Nth item in a list whose length Apple can change
            // between OS versions. Every current call site that
            // selects a specific item from a list now either uses
            // `.clickText` (a verified on-screen label) or, where no
            // label has been verified, a *single* Tab/Shift-Tab hop
            // documented `// UNVERIFIED macOS-26 label — blind
            // fallback` — lower risk than a multi-Tab count because it
            // doesn't assume how many rows precede the target.
            let steps = try SetupAutomation.sequence(for: version)
            // `BootAction` is `Equatable` but not `Hashable`, so this
            // stays an array checked with `contains` rather than a `Set`.
            let tabLikeActions: [BootAction] = [
                .key(.tab),
                .shortcut(.tab, modifiers: [.shift]),
            ]

            var runAction: BootAction?
            var runLength = 0
            for step in steps {
                if let runAction, step.action == runAction {
                    runLength += 1
                    continue
                }
                if runLength >= 3, step.action == .key(.space) {
                    Issue.record(
                        """
                        Found a hard-coded run of \(runLength) consecutive \(String(describing: runAction)) \
                        presses immediately followed by Space — this is the blind multi-Tab radio-navigation \
                        anti-pattern fixed in transferDataSteps(); convert it to clickText(<verified label>) \
                        or reduce it to a single documented Tab hop.
                        """
                    )
                }
                if tabLikeActions.contains(step.action) {
                    runAction = step.action
                    runLength = 1
                } else {
                    runAction = nil
                    runLength = 0
                }
            }
        }
    }

    // MARK: - Username and Password Customization

    @Suite("Credentials", .tags(.configuration))
    struct CredentialsTests {

        @Test("Default credentials use admin/admin (at least 5 occurrences)")
        func defaultCredentials() throws {
            let steps = try SetupAutomation.sequence(for: 15)
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
        func customUsername() throws {
            let steps = try SetupAutomation.sequence(for: 15, username: "runner", password: "secret123")
            let textSteps = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            let runnerCount = textSteps.filter { $0 == "runner" }.count
            #expect(runnerCount >= 2, "Custom username 'runner' should appear at least twice")
        }

        @Test("Custom password appears at least 3 times in the sequence")
        func customPassword() throws {
            let steps = try SetupAutomation.sequence(for: 15, username: "runner", password: "secret123")
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
        func customCredentialsReplaceDefaults() throws {
            let steps = try SetupAutomation.sequence(for: 15, username: "ci", password: "build")
            let textSteps = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            let hasAdmin = textSteps.contains { $0 == "admin" }
            #expect(!hasAdmin, "Custom credentials should fully replace 'admin'")
        }
    }

    // MARK: - Provisioner Install

    @Suite("Provisioner install", .tags(.configuration))
    struct ProvisionerInstallTests {

        @Test(
            "installProvisioner: false leaves the sequence byte-identical to the default",
            arguments: [15, 26]
        )
        func installProvisionerFalseIsUnchanged(version: Int) throws {
            let withFlag = try SetupAutomation.sequence(for: version, installProvisioner: false)
            let withoutFlag = try SetupAutomation.sequence(for: version)
            #expect(withFlag == withoutFlag)
        }

        @Test(
            "installProvisioner: true appends a step typing the installer command",
            arguments: [15, 26]
        )
        func installProvisionerTrueTypesInstallerCommand(version: Int) throws {
            let steps = try SetupAutomation.sequence(for: version, installProvisioner: true)
            let hasInstallerCommand = steps.contains { step in
                if case .text(let text) = step.action {
                    // Suffixed with a one-shot completion sentinel
                    // (`; echo SPOOK_"OK"_PKG`) rather than matched
                    // exactly — see the "sentinel markers never
                    // appear in typed text" regression test below for
                    // why the typed and executed forms of that
                    // sentinel deliberately differ.
                    return text.hasPrefix(
                        "sudo installer -pkg "
                            + "'/Library/Application Support/Spooktacular/provision/Spooktacular Provisioner.pkg' "
                            + "-target /"
                    )
                }
                return false
            }
            #expect(hasInstallerCommand, "Must type the exact installer(8) invocation")
        }

        @Test("installProvisioner: true mounts the share before running the installer")
        func installProvisionerTrueMountsBeforeInstalling() throws {
            let steps = try SetupAutomation.sequence(for: 15, installProvisioner: true)
            let textSteps = steps.enumerated().compactMap { index, step -> (Int, String)? in
                if case .text(let text) = step.action { return (index, text) }
                return nil
            }
            let mountIndex = try #require(textSteps.first {
                $0.1.hasPrefix("sudo mount_virtiofs spook-provision '/Library/Application Support/Spooktacular/provision'")
            }?.0)
            let installIndex = try #require(textSteps.first {
                $0.1.hasPrefix("sudo installer -pkg ")
            }?.0)
            #expect(mountIndex < installIndex, "Must mount the provisioning share before invoking installer(8)")
        }

        @Test("installProvisioner: true creates the mount point before mounting")
        func installProvisionerTrueCreatesMountPointFirst() throws {
            let steps = try SetupAutomation.sequence(for: 15, installProvisioner: true)
            let textSteps = steps.enumerated().compactMap { index, step -> (Int, String)? in
                if case .text(let text) = step.action { return (index, text) }
                return nil
            }
            let mkdirIndex = try #require(textSteps.first {
                $0.1.hasPrefix("sudo mkdir -p '/Library/Application Support/Spooktacular/provision'")
            }?.0)
            let mountIndex = try #require(textSteps.first {
                $0.1.hasPrefix("sudo mount_virtiofs")
            }?.0)
            #expect(mkdirIndex < mountIndex, "Must create the mount point before mounting it")
        }

        @Test("installProvisioner: true appends steps after SSH is enabled")
        func installProvisionerStepsFollowSSH() throws {
            let steps = try SetupAutomation.sequence(for: 15, installProvisioner: true)
            let textSteps = steps.enumerated().compactMap { index, step -> (Int, String)? in
                if case .text(let text) = step.action { return (index, text) }
                return nil
            }
            let sshIndex = try #require(textSteps.first {
                $0.1.contains("setremotelogin")
            }?.0)
            let mkdirIndex = try #require(textSteps.first {
                $0.1.hasPrefix("sudo mkdir -p")
            }?.0)
            #expect(sshIndex < mkdirIndex, "Provisioner steps must reuse the Terminal session opened for SSH")
        }

        @Test("installProvisioner: true waits after installer for the postinstall daemon bootstrap")
        func installProvisionerWaitsAfterInstaller() throws {
            let steps = try SetupAutomation.sequence(for: 15, installProvisioner: true)
            let installIndex = try #require(steps.firstIndex { step in
                if case .text(let text) = step.action { return text.hasPrefix("sudo installer -pkg ") }
                return false
            })
            // A handful of steps after the installer command (Return,
            // password, Return) there should be a generous wait so
            // `installer(8)`'s postinstall (`launchctl bootstrap`) has
            // time to finish before the caller starts polling SSH.
            let tail = steps[installIndex...]
            let hasLongWait = tail.contains { $0.delay >= 20 }
            #expect(hasLongWait, "Must allow time after installer(8) for the postinstall to bootstrap the daemon")
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

            let gateA = BootAction.expectScreen(containsAny: ["Continue"], timeout: 60)
            let gateB = BootAction.expectScreen(containsAny: ["Continue"], timeout: 60)
            let gateDifferentMarkers = BootAction.expectScreen(containsAny: ["Skip"], timeout: 60)
            let gateDifferentTimeout = BootAction.expectScreen(containsAny: ["Continue"], timeout: 30)
            #expect(gateA == gateB)
            #expect(gateA != gateDifferentMarkers)
            #expect(gateA != gateDifferentTimeout)
        }
    }

    // MARK: - Screen Gates

    /// Tests for the `expectScreen` gates that replaced blind
    /// fixed-delay waits at Setup Assistant screen transitions (bug
    /// #4: keystroke automation reported success while the guest
    /// never actually completed setup — see
    /// `plans/e2e-notes-2026-07.md`, ATTEMPT 3).
    ///
    /// These tests check the *sequence structure* — that gates exist
    /// at the right places with sane timeouts. ``SetupAutomationExecutor``'s
    /// own polling/timeout/diagnostic-capture behavior is covered
    /// separately in `SetupAutomationExecutorTests`, against a mock
    /// screen reader.
    @Suite("Screen gates", .tags(.configuration))
    struct ScreenGateTests {

        /// Every `expectScreen` step in `steps`, in order, with its
        /// index preserved for ordering assertions.
        private static func expectScreenSteps(
            _ steps: [BootStep]
        ) -> [(index: Int, markers: [String], timeout: TimeInterval)] {
            steps.enumerated().compactMap { index, step in
                guard case .expectScreen(let markers, let timeout) = step.action else { return nil }
                return (index, markers, timeout)
            }
        }

        @Test(
            "Sequoia sequence gates every named Setup Assistant screen transition",
            arguments: [15, 26]
        )
        func gatesCoverNamedTransitions(version: Int) throws {
            let steps = try SetupAutomation.sequence(for: version)
            let gates = Self.expectScreenSteps(steps)
            let allMarkers = gates.flatMap(\.markers).map { $0.lowercased() }
            let expectedSubstrings = [
                "english",           // language screen
                "country",           // country screen
                "migration",         // Migration Assistant / Transfer Data
                "account",           // account creation
                "apple id",          // Apple ID / Sign In
                "terms",             // Terms and Conditions
                "location",          // Location Services
                "time zone",         // time zone
                "spotlight",         // before opening Terminal
                "last login",        // Terminal shell ready, before SSH-enable sudo
            ]
            for expected in expectedSubstrings {
                #expect(
                    allMarkers.contains { $0.contains(expected) },
                    "No gate marker contains '\(expected)'"
                )
            }
        }

        @Test("Sequence still starts with a blind wait for VM boot — no marker is safe pre-language-selection")
        func firstStepIsNotAGate() throws {
            let steps = try SetupAutomation.sequence(for: 15)
            let first = try #require(steps.first)
            if case .expectScreen = first.action {
                Issue.record("First step must not be a screen gate — no locale-invariant marker exists before English is selected")
            }
            #expect(first.delay >= 30)
        }

        @Test(
            "Every screen gate uses a generous timeout (>= 60s)",
            arguments: [15, 26]
        )
        func gateTimeoutsAreGenerous(version: Int) throws {
            let steps = try SetupAutomation.sequence(for: version)
            let gates = Self.expectScreenSteps(steps)
            #expect(!gates.isEmpty)
            for gate in gates {
                #expect(gate.timeout >= 60, "Gate at step index \(gate.index) has too tight a timeout: \(gate.timeout)")
            }
        }

        @Test(
            "Screen gates replace the fixed pre-delay they guard — their own BootStep carries no additional delay",
            arguments: [15, 26]
        )
        func gateStepsCarryNoAdditionalFixedDelay(version: Int) throws {
            let steps = try SetupAutomation.sequence(for: version)
            for step in steps where isExpectScreen(step.action) {
                #expect(step.delay == 0, "expectScreen already polls adaptively; a nonzero BootStep delay would double-wait")
            }
        }

        private func isExpectScreen(_ action: BootAction) -> Bool {
            if case .expectScreen = action { return true }
            return false
        }

        @Test("installProvisioner: true gates the provisioner phase on a one-shot sentinel, never the (permanently visible) username")
        func provisionerPhaseIsGatedOnShellPrompt() throws {
            let steps = try SetupAutomation.sequence(for: 15, username: "runner", installProvisioner: true)
            let gates = Self.expectScreenSteps(steps)
            let mkdirIndex = try #require(steps.firstIndex { step in
                if case .text(let text) = step.action { return text.hasPrefix("sudo mkdir -p") }
                return false
            })
            let precedingGate = try #require(
                gates.last { $0.index < mkdirIndex },
                "The provisioner phase must be gated before its first sudo command"
            )
            // The account's own username sits permanently in the zsh
            // `PS1` prompt (`/etc/zshrc`), so a gate that waits for it
            // is satisfied by *any* prior command's leftover prompt —
            // resolving instantly and synchronizing nothing. This is
            // the exact self-satisfaction bug a one-shot sentinel
            // (``SetupAutomation/sentinelMarker(_:)``) replaces.
            #expect(
                !precedingGate.markers.contains("runner"),
                "The gate must not use the account username as its marker"
            )
            #expect(
                precedingGate.markers.contains { $0.hasPrefix("SPOOK_OK_") },
                "The provisioner phase must be gated on a one-shot sentinel marker"
            )
        }

        @Test("installProvisioner: true gates every sudo command on its own sentinel before the next command is typed")
        func eachProvisionerCommandGatedBeforeNext() throws {
            let steps = try SetupAutomation.sequence(for: 15, installProvisioner: true)
            let gates = Self.expectScreenSteps(steps)
            let commandOrder = ["mkdir", "mount_virtiofs", "installer"]
            let commandIndices = try commandOrder.map { fragment in
                try #require(steps.firstIndex { step in
                    if case .text(let text) = step.action { return text.contains(fragment) }
                    return false
                })
            }
            for pair in zip(commandIndices, commandIndices.dropFirst()) {
                #expect(
                    gates.contains { $0.index > pair.0 && $0.index < pair.1 },
                    "Must gate on a completion sentinel between typing one provisioner command and the next"
                )
            }
        }

        @Test("Sentinel gate markers never appear verbatim in any typed command — regression guard against self-satisfying gates")
        func sentinelMarkersNeverAppearInTypedText() throws {
            let steps = try SetupAutomation.sequence(for: 15, installProvisioner: true)
            let gates = Self.expectScreenSteps(steps)
            let sentinelMarkers = Set(gates.flatMap(\.markers).filter { $0.hasPrefix("SPOOK_OK_") })
            #expect(!sentinelMarkers.isEmpty, "Expected at least one sentinel-gated step in the sequence")

            let typedStrings = steps.compactMap { step -> String? in
                if case .text(let text) = step.action { return text }
                return nil
            }
            for marker in sentinelMarkers {
                for typed in typedStrings {
                    #expect(
                        !typed.contains(marker),
                        """
                        Typed command '\(typed)' contains sentinel marker '\(marker)' verbatim — the gate would \
                        resolve while the command is still on screen mid-type, before it has actually executed, \
                        exactly the self-satisfaction bug this sentinel design fixes.
                        """
                    )
                }
            }
        }

        @Test("enableSSHSteps gates on the systemsetup command's own completion sentinel after it is typed")
        func sshEnableIsGatedOnItsOwnSentinel() throws {
            let steps = try SetupAutomation.sequence(for: 15)
            let gates = Self.expectScreenSteps(steps)
            let sshonGate = try #require(
                gates.first { $0.markers.contains("SPOOK_OK_SSHON") },
                "Must gate on the systemsetup command's completion sentinel"
            )
            let sudoIndex = try #require(steps.firstIndex { step in
                if case .text(let text) = step.action { return text.contains("setremotelogin") }
                return false
            })
            #expect(sshonGate.index > sudoIndex, "The SSHON gate must come after the systemsetup command is typed")
        }

        @Test("Terminal/SSH phase gates Spotlight opening before Terminal is typed, and a shell prompt before the sudo command")
        func terminalPhaseGatesBothSpotlightAndShellReady() throws {
            let steps = try SetupAutomation.sequence(for: 15)
            let gates = Self.expectScreenSteps(steps)
            let terminalTextIndex = try #require(steps.firstIndex { step in
                if case .text(let text) = step.action { return text == "Terminal" }
                return false
            })
            let sudoIndex = try #require(steps.firstIndex { step in
                if case .text(let text) = step.action { return text.contains("setremotelogin") }
                return false
            })
            let spotlightGate = gates.last { $0.index < terminalTextIndex }
            let terminalReadyGate = gates.last { $0.index < sudoIndex && $0.index > terminalTextIndex }
            #expect(spotlightGate != nil, "Must gate on Spotlight being open before typing 'Terminal'")
            #expect(terminalReadyGate != nil, "Must gate on the shell prompt being ready before typing the sudo command")
        }
    }
}
