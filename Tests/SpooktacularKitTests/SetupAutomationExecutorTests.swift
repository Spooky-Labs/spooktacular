import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// Tests for ``SetupAutomationExecutor``'s screen-gate behavior: the
/// `expectScreen` action's polling, timeout, and diagnostic-artifact
/// logic, exercised against mock ``KeyboardDriver``/``ScreenReader``
/// doubles instead of a real VM.
///
/// This suite exists because bug #4 (Setup Assistant automation
/// reporting success while the guest never actually completed setup
/// — see `plans/e2e-notes-2026-07.md`, ATTEMPT 3) traced back to
/// `SetupAutomationExecutor` having zero unit test coverage: the only
/// way to observe a desync was a ~40-minute live e2e run. These tests
/// check the gate primitive itself (poll-until-match, timeout,
/// diagnostic capture) in milliseconds, against mocks that can
/// deterministically script "the marker never appears."
@Suite("SetupAutomationExecutor", .tags(.configuration))
@MainActor
struct SetupAutomationExecutorTests {

    // MARK: - Helpers

    private func recognized(_ text: String) -> RecognizedText {
        RecognizedText(
            text: text,
            boundingBox: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.05),
            confidence: 0.95
        )
    }

    // MARK: - Gate Resolves

    @Test("expectScreen resolves immediately when the marker is already visible on the first poll")
    func gateResolvesImmediately() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Please Continue")]])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Continue"], timeout: 5)),
            BootStep(delay: 0, action: .text("hello")),
        ]

        try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: reader)

        #expect(reader.recognizeTextCallCount == 1)
        #expect(driver.actions == [.text("hello")])
    }

    @Test("expectScreen polls until a later frame satisfies the marker, blocking subsequent keystrokes until then")
    func gateResolvesAfterPolling() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [
            [recognized("Loading")],
            [recognized("Loading")],
            [recognized("Please Continue")],
        ])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Continue"], timeout: 5)),
            BootStep(delay: 0, action: .text("hello")),
        ]

        try await SetupAutomationExecutor.run(
            steps: steps,
            using: driver,
            screenReader: reader,
            screenGatePollInterval: 0.01
        )

        // Deterministic regardless of wall-clock timing: ScriptedScreenReader
        // advances one frame per call, not per elapsed second.
        #expect(reader.recognizeTextCallCount == 3)
        #expect(driver.actions == [.text("hello")])
    }

    @Test("expectScreen matches any of several candidate markers")
    func gateMatchesAnyCandidateMarker() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Migration Assistant")]])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(
                containsAny: ["Transfer Your Data", "Migration Assistant"],
                timeout: 5
            )),
        ]

        try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: reader)

        #expect(reader.recognizeTextCallCount == 1)
    }

    // MARK: - Gate Timeout

    @Test("expectScreen throws a diagnostic error naming the step/markers/excerpt on timeout, blocking later steps")
    func gateTimesOutWithDiagnosticError() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Unrelated Screen Text")]])
        let steps = [
            BootStep(delay: 0, action: .text("before")),
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Continue"], timeout: 0.05)),
            BootStep(delay: 0, action: .text("after")),
        ]

        do {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                screenGatePollInterval: 0.01
            )
            Issue.record("Expected the gate to time out")
        } catch let error as SetupAutomationExecutorError {
            guard case .screenGateTimedOut(
                let stepIndex, let totalSteps, let expectedMarkers, let actualTextExcerpt, let timeout, _
            ) = error else {
                Issue.record("Expected .screenGateTimedOut, got \(error)")
                return
            }
            #expect(stepIndex == 1)
            #expect(totalSteps == 3)
            #expect(expectedMarkers == ["Continue"])
            #expect(actualTextExcerpt.contains("Unrelated Screen Text"))
            #expect(timeout == 0.05)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // Only the step before the gate should have run — the gate
        // must block the "after" step from ever being sent into a
        // possibly-desynchronized screen.
        #expect(driver.actions == [.text("before")])
    }

    @Test("Without a screen reader, expectScreen falls back to a fixed delay and never fails")
    func gateFallsBackWithoutScreenReader() async throws {
        let driver = RecordingKeyboardDriver()
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Continue"], timeout: 0.02)),
            BootStep(delay: 0, action: .text("hello")),
        ]

        try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: nil)

        #expect(driver.actions == [.text("hello")])
    }

    // MARK: - clickText

    /// Tests for the `.clickText` action introduced to replace blind
    /// Tab/Space radio and button navigation (see
    /// `SetupAutomationTests`'s `countryScreenConfirmsViaClickText`
    /// and `transferDataScreenConfirmsViaClickText` for the sequence-
    /// level regression tests these two live-e2e bugs produced). These
    /// tests cover the executor's dispatch of the action itself: the
    /// OCR-rect-to-click-point conversion on a hit, and — since a
    /// `.clickText` miss used to throw a bare `ScreenReaderError` with
    /// no screenshot/OCR dump, unlike an `expectScreen` gate timeout —
    /// that a miss now produces the same diagnostic artifacts.
    @Test("clickText converts the matched text's Vision bounding box (bottom-left origin) into a top-left-origin click point")
    func clickTextClicksTheCenterOfTheMatchedBoundingBox() async throws {
        let driver = RecordingKeyboardDriver()
        // Chosen as exact binary fractions (powers of two) so the
        // computed center survives floating-point arithmetic without
        // rounding — avoids a flaky equality assertion below. Vision's
        // bottom-left-origin box (x:0.125, y:0.5, w:0.25, h:0.125) has
        // center (0.25, 0.5625); flipping y for a top-left-origin
        // click point gives (0.25, 0.4375).
        let match = RecognizedText(
            text: "Continue",
            boundingBox: NormalizedRect(x: 0.125, y: 0.5, width: 0.25, height: 0.125),
            confidence: 0.95
        )
        let reader = ScriptedScreenReader(frames: [[match]])
        let steps = [
            BootStep(delay: 0, action: .clickText("Continue")),
        ]

        try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: reader)

        #expect(driver.actions == [.click(x: 0.25, y: 0.4375)])
    }

    @Test("Without a screen reader, clickText is skipped rather than clicking blindly or throwing")
    func clickTextSkippedWithoutScreenReader() async throws {
        let driver = RecordingKeyboardDriver()
        let steps = [
            BootStep(delay: 0, action: .clickText("Continue")),
            BootStep(delay: 0, action: .text("after")),
        ]

        try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: nil)

        #expect(driver.actions == [.text("after")])
    }

    @Test("clickText throws a diagnostic error and saves an OCR dump when its target is never found, matching expectScreen's timeout behavior")
    func clickTextNotFoundSavesDiagnosticArtifacts() async throws {
        let tempDir = TempDirectory()
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Set up as new")]])
        let steps = [
            BootStep(delay: 0, action: .clickText("Continue", timeout: 0.02)),
        ]

        await #expect(throws: SetupAutomationExecutorError.self) {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                diagnosticsDirectory: tempDir.url
            )
        }

        // No click was ever sent for a target that was never found.
        #expect(driver.actions.isEmpty)

        let textURL = tempDir.file("automation-failure-step1.txt")
        #expect(FileManager.default.fileExists(atPath: textURL.path))
        let dump = try String(contentsOf: textURL, encoding: .utf8)
        #expect(dump.contains("Set up as new"))
        #expect(dump.contains("Continue"))
    }

    @Test("clickText not-found throws the same diagnostic case expectScreen uses, naming the single target as its one-element marker list")
    func clickTextNotFoundThrowsScreenGateTimedOut() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Unrelated Screen Text")]])
        let steps = [
            BootStep(delay: 0, action: .text("before")),
            BootStep(delay: 0, action: .clickText("Set up as new", timeout: 0.02)),
            BootStep(delay: 0, action: .text("after")),
        ]

        do {
            try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: reader)
            Issue.record("Expected clickText to throw when its target is never found")
        } catch let error as SetupAutomationExecutorError {
            guard case .screenGateTimedOut(
                let stepIndex, let totalSteps, let expectedMarkers, let actualTextExcerpt, let timeout, _
            ) = error else {
                Issue.record("Expected .screenGateTimedOut, got \(error)")
                return
            }
            #expect(stepIndex == 1)
            #expect(totalSteps == 3)
            #expect(expectedMarkers == ["Set up as new"])
            #expect(actualTextExcerpt.contains("Unrelated Screen Text"))
            #expect(timeout == 0.02)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        // The gate must block the "after" step from ever being sent.
        #expect(driver.actions == [.text("before")])
    }

    @Test("clickText not-found without a diagnostics directory still throws but reports no artifact directory")
    func clickTextNotFoundWithoutDiagnosticsDirectoryStillThrows() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Wrong Screen")]])
        let steps = [
            BootStep(delay: 0, action: .clickText("Right Target", timeout: 0.02)),
        ]

        do {
            try await SetupAutomationExecutor.run(steps: steps, using: driver, screenReader: reader)
            Issue.record("Expected clickText to throw when its target is never found")
        } catch let error as SetupAutomationExecutorError {
            guard case .screenGateTimedOut(_, _, _, _, _, let artifactDirectory) = error else {
                Issue.record("Expected .screenGateTimedOut, got \(error)")
                return
            }
            #expect(artifactDirectory == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Diagnostic Artifacts

    @Test("On timeout, the full OCR dump is saved to the diagnostics directory even without screenshot support")
    func timeoutSavesOCRDumpWithoutScreenshot() async throws {
        let tempDir = TempDirectory()
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Wrong Screen")]])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Right Screen"], timeout: 0.02)),
        ]

        await #expect(throws: SetupAutomationExecutorError.self) {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                diagnosticsDirectory: tempDir.url,
                screenGatePollInterval: 0.01
            )
        }

        let textURL = tempDir.file("automation-failure-step1.txt")
        let pngURL = tempDir.file("automation-failure-step1.png")
        #expect(FileManager.default.fileExists(atPath: textURL.path))
        #expect(!FileManager.default.fileExists(atPath: pngURL.path))

        let dump = try String(contentsOf: textURL, encoding: .utf8)
        #expect(dump.contains("Wrong Screen"))
        #expect(dump.contains("Right Screen"))
    }

    @Test("On timeout, a screenshot is saved alongside the OCR dump when the screen reader supports capture")
    func timeoutSavesScreenshotWhenSupported() async throws {
        let tempDir = TempDirectory()
        let driver = RecordingKeyboardDriver()
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47])  // PNG magic bytes; content is irrelevant to this test
        let reader = ScreenshotCapableScreenReader(frames: [[recognized("Wrong Screen")]], pngData: pngBytes)
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Right Screen"], timeout: 0.02)),
        ]

        await #expect(throws: SetupAutomationExecutorError.self) {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                diagnosticsDirectory: tempDir.url,
                screenGatePollInterval: 0.01
            )
        }

        #expect(reader.capturePNGCallCount == 1)
        let pngURL = tempDir.file("automation-failure-step1.png")
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
        let savedData = try Data(contentsOf: pngURL)
        #expect(savedData == pngBytes)
    }

    @Test("Without a diagnostics directory, timeout still throws but reports no artifact directory")
    func timeoutWithoutDiagnosticsDirectoryStillThrows() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[recognized("Wrong Screen")]])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Right Screen"], timeout: 0.02)),
        ]

        do {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                screenGatePollInterval: 0.01
            )
            Issue.record("Expected the gate to time out")
        } catch let error as SetupAutomationExecutorError {
            guard case .screenGateTimedOut(_, _, _, _, _, let artifactDirectory) = error else {
                Issue.record("Expected .screenGateTimedOut, got \(error)")
                return
            }
            #expect(artifactDirectory == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("An empty OCR observation produces a readable 'no text recognized' excerpt instead of an empty string")
    func timeoutWithNoObservedTextProducesReadableExcerpt() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = ScriptedScreenReader(frames: [[]])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Anything"], timeout: 0.02)),
        ]

        do {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                screenGatePollInterval: 0.01
            )
            Issue.record("Expected the gate to time out")
        } catch let error as SetupAutomationExecutorError {
            guard case .screenGateTimedOut(_, _, _, let actualTextExcerpt, _, _) = error else {
                Issue.record("Expected .screenGateTimedOut, got \(error)")
                return
            }
            #expect(actualTextExcerpt == "(no text recognized)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    // MARK: - Accurate Re-Scan on Timeout

    @Test("On timeout, the saved OCR dump prefers a fresh accurate re-scan over the last (fast-level) poll, when the reader supports one")
    func timeoutPrefersAccurateRescanForSavedDump() async throws {
        let tempDir = TempDirectory()
        let driver = RecordingKeyboardDriver()
        let reader = AccurateCapableScreenReader(
            frames: [[recognized("Fast Level Text")]],
            accurateFrame: [recognized("Accurate Level Text")]
        )
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Right Screen"], timeout: 0.02)),
        ]

        await #expect(throws: SetupAutomationExecutorError.self) {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                diagnosticsDirectory: tempDir.url,
                screenGatePollInterval: 0.01
            )
        }

        #expect(reader.recognizeTextAccurateCallCount == 1)
        let textURL = tempDir.file("automation-failure-step1.txt")
        let dump = try String(contentsOf: textURL, encoding: .utf8)
        #expect(dump.contains("Accurate Level Text"))
        #expect(!dump.contains("Fast Level Text"))
    }

    @Test("On timeout, the thrown error's excerpt still reflects the last poll, even when an accurate re-scan exists for the saved dump")
    func timeoutErrorExcerptUsesLastPollNotAccurateRescan() async throws {
        let driver = RecordingKeyboardDriver()
        let reader = AccurateCapableScreenReader(
            frames: [[recognized("Fast Level Text")]],
            accurateFrame: [recognized("Accurate Level Text")]
        )
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Right Screen"], timeout: 0.02)),
        ]

        do {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                screenGatePollInterval: 0.01
            )
            Issue.record("Expected the gate to time out")
        } catch let error as SetupAutomationExecutorError {
            guard case .screenGateTimedOut(_, _, _, let actualTextExcerpt, _, _) = error else {
                Issue.record("Expected .screenGateTimedOut, got \(error)")
                return
            }
            // Cheap-and-already-in-hand for the thrown error; the
            // extra Vision latency of an accurate re-scan is spent
            // only once, on the saved dump — see
            // `timeoutPrefersAccurateRescanForSavedDump`.
            #expect(actualTextExcerpt.contains("Fast Level Text"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("On timeout, if the accurate re-scan throws, the saved dump falls back to the last poll's OCR instead of losing the artifact")
    func timeoutFallsBackToLastPollWhenAccurateRescanThrows() async throws {
        let tempDir = TempDirectory()
        let driver = RecordingKeyboardDriver()
        let reader = ThrowingAccurateScreenReader(frames: [[recognized("Fast Level Text")]])
        let steps = [
            BootStep(delay: 0, action: .expectScreen(containsAny: ["Right Screen"], timeout: 0.02)),
        ]

        await #expect(throws: SetupAutomationExecutorError.self) {
            try await SetupAutomationExecutor.run(
                steps: steps,
                using: driver,
                screenReader: reader,
                diagnosticsDirectory: tempDir.url,
                screenGatePollInterval: 0.01
            )
        }

        let textURL = tempDir.file("automation-failure-step1.txt")
        let dump = try String(contentsOf: textURL, encoding: .utf8)
        #expect(dump.contains("Fast Level Text"))
    }

    @Test("screenGateTimedOut's error description names the step and includes the actual-text excerpt")
    func screenGateTimedOutErrorDescriptionIsActionable() {
        let error = SetupAutomationExecutorError.screenGateTimedOut(
            stepIndex: 4,
            totalSteps: 89,
            expectedMarkers: ["Continue", "Skip"],
            actualTextExcerpt: "Unexpected Dialog",
            timeout: 60,
            artifactDirectory: URL(filePath: "/tmp/example")
        )
        #expect(error.errorDescription?.contains("5/89") == true, "Message must be 1-based, human readable")
        #expect(error.errorDescription?.contains("Continue") == true)
        #expect(error.errorDescription?.contains("Unexpected Dialog") == true)
        #expect(error.recoverySuggestion?.contains("/tmp/example") == true)
    }
}

// MARK: - Test Doubles

/// Records every action sent through it instead of touching a real
/// VM, so tests can assert both content and ordering — in particular,
/// that no keystroke after a screen gate was sent until the gate
/// resolved.
private final class RecordingKeyboardDriver: KeyboardDriver, @unchecked Sendable {

    enum RecordedAction: Equatable {
        case key(KeyCode, modifiers: [Modifier])
        case text(String)
        case click(x: Double, y: Double)
    }

    private(set) var actions: [RecordedAction] = []

    func sendKey(_ keyCode: KeyCode, modifiers: [Modifier]) async throws {
        actions.append(.key(keyCode, modifiers: modifiers))
    }

    func sendText(_ text: String) async throws {
        actions.append(.text(text))
    }

    func clickAt(x: Double, y: Double) async throws {
        actions.append(.click(x: x, y: y))
    }
}

/// A ``ScreenReader`` test double that returns a fixed, scripted
/// sequence of OCR "frames" on successive ``recognizeText()`` calls.
/// Once the script is exhausted, the last frame repeats — so a test
/// can express "never matches" without an unbounded array, and the
/// call count is driven by how many times the executor actually
/// polled rather than wall-clock time, keeping timing-sensitive
/// assertions deterministic.
private final class ScriptedScreenReader: ScreenReader, @unchecked Sendable {
    fileprivate let frames: [[RecognizedText]]
    private(set) var recognizeTextCallCount = 0

    init(frames: [[RecognizedText]]) {
        self.frames = frames
    }

    func recognizeText() async throws -> [RecognizedText] {
        recognizeTextCallCount += 1
        guard !frames.isEmpty else { return [] }
        let index = min(recognizeTextCallCount - 1, frames.count - 1)
        return frames[index]
    }

    func waitForText(_ text: String, timeout: TimeInterval) async throws -> RecognizedText {
        let results = try await recognizeText()
        guard let match = results.first(where: { $0.text.localizedCaseInsensitiveContains(text) }) else {
            throw ScreenReaderError.textNotFound(text, timeout: timeout)
        }
        return match
    }
}

/// A ``ScriptedScreenReader`` that also conforms to
/// ``ScreenshotCapturing``, for exercising the screenshot-save path
/// on gate timeout — a plain ``ScriptedScreenReader`` deliberately
/// does NOT conform, to also exercise the "no screenshot support"
/// path in the same suite.
private final class ScreenshotCapableScreenReader: ScreenReader, ScreenshotCapturing, @unchecked Sendable {
    private let inner: ScriptedScreenReader
    var pngData: Data?
    private(set) var capturePNGCallCount = 0

    init(frames: [[RecognizedText]], pngData: Data?) {
        self.inner = ScriptedScreenReader(frames: frames)
        self.pngData = pngData
    }

    var recognizeTextCallCount: Int { inner.recognizeTextCallCount }

    func recognizeText() async throws -> [RecognizedText] {
        try await inner.recognizeText()
    }

    func waitForText(_ text: String, timeout: TimeInterval) async throws -> RecognizedText {
        try await inner.waitForText(text, timeout: timeout)
    }

    func capturePNG() async throws -> Data? {
        capturePNGCallCount += 1
        return pngData
    }
}

/// A ``ScriptedScreenReader`` that also conforms to
/// ``AccurateTextCapturing``, returning a fixed, distinguishable
/// frame from ``recognizeTextAccurate()`` — separate from whatever
/// ``recognizeText()``'s scripted (fast-level) frames say — so a test
/// can prove which of the two the saved diagnostic dump actually
/// used.
private final class AccurateCapableScreenReader: ScreenReader, AccurateTextCapturing, @unchecked Sendable {
    private let inner: ScriptedScreenReader
    private let accurateFrame: [RecognizedText]
    private(set) var recognizeTextAccurateCallCount = 0

    init(frames: [[RecognizedText]], accurateFrame: [RecognizedText]) {
        self.inner = ScriptedScreenReader(frames: frames)
        self.accurateFrame = accurateFrame
    }

    func recognizeText() async throws -> [RecognizedText] {
        try await inner.recognizeText()
    }

    func waitForText(_ text: String, timeout: TimeInterval) async throws -> RecognizedText {
        try await inner.waitForText(text, timeout: timeout)
    }

    func recognizeTextAccurate() async throws -> [RecognizedText] {
        recognizeTextAccurateCallCount += 1
        return accurateFrame
    }
}

/// A ``ScriptedScreenReader`` that also conforms to
/// ``AccurateTextCapturing``, but whose accurate pass always throws —
/// exercises the "fall back to the last poll's OCR" path when a
/// second, more-accurate Vision request fails after the routine
/// (fast-level) polling already succeeded.
private final class ThrowingAccurateScreenReader: ScreenReader, AccurateTextCapturing, @unchecked Sendable {
    private let inner: ScriptedScreenReader

    init(frames: [[RecognizedText]]) {
        self.inner = ScriptedScreenReader(frames: frames)
    }

    func recognizeText() async throws -> [RecognizedText] {
        try await inner.recognizeText()
    }

    func waitForText(_ text: String, timeout: TimeInterval) async throws -> RecognizedText {
        try await inner.waitForText(text, timeout: timeout)
    }

    func recognizeTextAccurate() async throws -> [RecognizedText] {
        throw ScreenReaderError.textNotFound("accurate rescan unavailable", timeout: 0)
    }
}
