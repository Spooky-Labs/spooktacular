import Foundation
import SpooktacularCore
import SpooktacularApplication
import os
@preconcurrency import Virtualization

/// Errors that can occur during Setup Assistant automation execution.
public enum SetupAutomationExecutorError: Error, Sendable, LocalizedError {

    /// The virtual machine has no underlying `VZVirtualMachine` instance.
    case virtualMachineInvalidated

    /// A character in a `.text` action could not be mapped to a key code.
    case unmappableCharacter(Character)

    /// An `.expectScreen` gate never found any of its expected
    /// markers before timing out, **or** a `.clickText` action never
    /// found its click target before timing out.
    ///
    /// Both actions share this case because they share a failure
    /// shape: each polls the screen for specific text and gives up
    /// after a timeout. `.clickText` reports a single-element
    /// `expectedMarkers` array (its one target string) rather than a
    /// dedicated case, so both failure modes get the same diagnostic
    /// treatment — see ``SetupAutomationExecutor``'s `.clickText`
    /// dispatch, which saves artifacts exactly like
    /// ``SetupAutomationExecutor``'s `expectScreen` gate does, instead
    /// of surfacing a bare ``SpooktacularCore/ScreenReaderError`` with
    /// no screenshot or OCR dump attached.
    ///
    /// Carries everything needed to diagnose a desynchronized
    /// automation run without re-running it: which step failed, what
    /// the sequence was looking for, and a truncated excerpt of what
    /// the screen actually showed. When ``SetupAutomationExecutor``
    /// was given a diagnostics directory, the full OCR dump (and a
    /// screenshot, when the screen reader supports capture) was
    /// already written to disk before this error was thrown —
    /// ``artifactDirectory`` names where.
    ///
    /// - Parameters:
    ///   - stepIndex: Zero-based index of the failed step within the
    ///     sequence passed to ``SetupAutomationExecutor/run(steps:using:screenReader:diagnosticsDirectory:screenGatePollInterval:)``.
    ///   - totalSteps: Total step count, for a human-readable
    ///     "step X/Y" message.
    ///   - expectedMarkers: The candidate substrings the gate was
    ///     waiting for (`expectScreen`'s `containsAny`), or the single
    ///     target string wrapped in an array for `.clickText`.
    ///   - actualTextExcerpt: A truncated join of every OCR text
    ///     region observed on the final poll before timeout.
    ///   - timeout: The gate's configured timeout, in seconds.
    ///   - artifactDirectory: The directory the OCR dump (and
    ///     optional screenshot) were written to, or `nil` if no
    ///     diagnostics directory was configured or the write failed.
    case screenGateTimedOut(
        stepIndex: Int,
        totalSteps: Int,
        expectedMarkers: [String],
        actualTextExcerpt: String,
        timeout: TimeInterval,
        artifactDirectory: URL?
    )

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .virtualMachineInvalidated:
            "The virtual machine is invalidated and cannot receive keyboard events."
        case .unmappableCharacter(let char):
            "Cannot map character '\(char)' to a virtual key code."
        case .screenGateTimedOut(let stepIndex, let totalSteps, let expectedMarkers, let actualTextExcerpt, let timeout, _):
            "Setup Assistant automation step \(stepIndex + 1)/\(totalSteps) timed out after \(Int(timeout))s "
                + "waiting for the screen to show one of ["
                + expectedMarkers.map { "'\($0)'" }.joined(separator: ", ")
                + "]. Actual screen text: \"\(actualTextExcerpt)\"."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .virtualMachineInvalidated:
            "Restart the VM and retry the setup automation."
        case .unmappableCharacter:
            "Use only ASCII alphanumeric characters, common punctuation, and whitespace in usernames and passwords."
        case .screenGateTimedOut(_, _, _, _, _, let artifactDirectory):
            artifactDirectory.map { directory in
                "The automation desynchronized from the actual Setup Assistant screen — the sequence's marker "
                    + "text may be stale for this macOS version, or a keystroke landed somewhere unexpected. "
                    + "Inspect the saved OCR dump (and screenshot, if captured) at \(directory.path)."
            } ?? "The automation desynchronized from the actual Setup Assistant screen — the sequence's marker "
                + "text may be stale for this macOS version, or a keystroke landed somewhere unexpected. "
                + "Re-run with a diagnostics directory configured to capture a screenshot and OCR dump."
        }
    }
}

/// Drives macOS Setup Assistant automation by sending keyboard events
/// to a running `VZVirtualMachine` through a ``KeyboardDriver``.
///
/// `SetupAutomationExecutor` iterates over a sequence of ``BootStep``s,
/// waiting for each step's delay, then dispatching the keyboard action
/// through the provided ``KeyboardDriver`` implementation.
///
/// ## How It Works
///
/// 1. The caller provides a ``KeyboardDriver`` that knows how to
///    deliver keyboard events to the VM (e.g., via an offscreen
///    `NSWindow` with a `VZVirtualMachineView`).
/// 2. For each ``BootStep``, the executor waits for the step's delay,
///    then sends the action through the driver.
/// 3. After all steps complete, control returns to the caller.
///
/// This approach matches the technique used by
/// [Tart](https://github.com/cirruslabs/tart) for Packer `boot_command`
/// sequences, which has been proven reliable across macOS 13 through 26.
///
/// ## Example
///
/// ```swift
/// let driver = VZKeyboardDriver(virtualMachine: vm)
/// let steps = SetupAutomation.sequence(for: 15)
/// try await SetupAutomationExecutor.run(steps: steps, using: driver)
/// ```
///
/// ## Thread Safety
///
/// All methods are `@MainActor` because `VZVirtualMachine` and
/// keyboard event delivery are main-thread-only.
public enum SetupAutomationExecutor {

    // MARK: - Public API

    /// Executes a sequence of ``BootStep``s by sending keyboard events
    /// through the given driver.
    ///
    /// Iterates over each step, waits for its delay, then dispatches
    /// the action through the ``KeyboardDriver``. The method returns
    /// after the last step completes.
    ///
    /// When a ``ScreenReader`` is provided, `.waitForText`,
    /// `.clickText`, and `.expectScreen` actions use Vision OCR to
    /// detect screen content. Without a screen reader, `.waitForText`
    /// and `.expectScreen` fall back to a fixed delay and `.clickText`
    /// is skipped. All existing timing-based sequences continue to
    /// work without a screen reader.
    ///
    /// Completing every step does **not** mean Setup Assistant
    /// actually finished — see the log line this method emits on
    /// completion, and rely on a downstream guest-visible check (SSH
    /// reachability, in every current caller) as the real success
    /// gate. `.expectScreen` gates make a desync far less likely to
    /// go unnoticed than blind keystroke replay did, but they only
    /// cover the transitions ``SetupAutomation`` actually gates —
    /// see that type's per-screen documentation for which ones.
    ///
    /// - Parameters:
    ///   - steps: The ordered boot step sequence from
    ///     ``SetupAutomation/sequence(for:username:password:installProvisioner:)``.
    ///   - driver: A ``KeyboardDriver`` that delivers keyboard events
    ///     to the virtual machine.
    ///   - screenReader: An optional ``ScreenReader`` for screen-aware
    ///     actions. Pass `nil` to use timing-based fallbacks.
    ///   - diagnosticsDirectory: Where to save a screenshot (when the
    ///     screen reader conforms to ``SpooktacularCore/ScreenshotCapturing``)
    ///     and the full OCR dump when an `.expectScreen` gate times
    ///     out. Pass `nil` (the default) to skip saving artifacts —
    ///     useful for tests and for callers with no VM bundle
    ///     directory to write into. Callers with a bundle should pass
    ///     its provisioning directory (e.g.
    ///     `VirtualMachineBundle.provisionDirectoryURL`), the same
    ///     place first-boot provisioning evidence already lands.
    ///   - screenGatePollInterval: Seconds between OCR polls inside
    ///     `.expectScreen`. Defaults to 3, matching ``VZScreenReader``'s
    ///     own default polling cadence (see its "Polling Strategy"
    ///     documentation for the rationale: `.fast`-level recognition
    ///     plus a 3-second cadence together bound how much main-actor
    ///     time a long-open gate spends in Vision requests). Tests
    ///     pass a much smaller value to keep gate tests fast.
    /// - Throws: ``SetupAutomationExecutorError/unmappableCharacter(_:)``
    ///   if a text character cannot be converted to a key code,
    ///   ``SetupAutomationExecutorError/screenGateTimedOut(stepIndex:totalSteps:expectedMarkers:actualTextExcerpt:timeout:artifactDirectory:)``
    ///   if an `.expectScreen` gate never finds its marker, or any
    ///   error thrown by the driver or screen reader.
    @MainActor
    public static func run(
        steps: [BootStep],
        using driver: any KeyboardDriver,
        screenReader: (any ScreenReader)? = nil,
        diagnosticsDirectory: URL? = nil,
        screenGatePollInterval: TimeInterval = 3
    ) async throws {
        Log.provision.info("Starting Setup Assistant automation (\(steps.count) steps)")
        if screenReader != nil {
            Log.provision.info("Screen reader available — screen-aware actions enabled")
        }

        for (index, step) in steps.enumerated() {
            if step.delay > 0 {
                Log.provision.debug(
                    "Step \(index + 1)/\(steps.count): waiting \(step.delay, privacy: .public)s"
                )
                try await Task.sleep(for: .seconds(step.delay))
            }

            try await performAction(
                step.action,
                using: driver,
                screenReader: screenReader,
                diagnosticsDirectory: diagnosticsDirectory,
                screenGatePollInterval: screenGatePollInterval,
                stepIndex: index,
                totalSteps: steps.count
            )
        }

        // Deliberately NOT "automation complete" or "succeeded": every
        // keystroke was sent and every screen gate that exists along
        // the way was satisfied, but that is not the same as Setup
        // Assistant having actually finished on the guest — this
        // method has no way to observe state that isn't covered by a
        // gate. Callers must still treat a downstream guest-visible
        // check (SSH reachability, in every current caller) as the
        // real success signal; this log line exists to stop a reader
        // from mistaking "loop finished" for "setup succeeded", which
        // is exactly the false signal that let bug #4 (SSH refused,
        // provisioner never installed, hostname still OOBE-default)
        // report success.
        Log.provision.notice(
            "Setup Assistant keystroke sequence completed (\(steps.count) steps) — guest state unverified until SSH confirm"
        )
    }

    // MARK: - Action Dispatch

    /// Performs a single ``BootAction`` by sending the appropriate
    /// keyboard events through the driver.
    ///
    /// - Parameters:
    ///   - action: The action to perform.
    ///   - driver: The ``KeyboardDriver`` to send events through.
    ///   - screenReader: An optional ``ScreenReader`` for screen-aware actions.
    ///   - diagnosticsDirectory: Where `.expectScreen` saves failure
    ///     artifacts on timeout. See ``run(steps:using:screenReader:diagnosticsDirectory:screenGatePollInterval:)``.
    ///   - screenGatePollInterval: Seconds between OCR polls inside
    ///     `.expectScreen`.
    ///   - stepIndex: The zero-based index for logging.
    ///   - totalSteps: The total step count for logging.
    @MainActor
    private static func performAction(
        _ action: BootAction,
        using driver: any KeyboardDriver,
        screenReader: (any ScreenReader)?,
        diagnosticsDirectory: URL?,
        screenGatePollInterval: TimeInterval,
        stepIndex: Int,
        totalSteps: Int
    ) async throws {
        switch action {
        case .text(let string):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): typing \(string.count) character(s)"
            )
            try await driver.sendText(string)

        case .key(let keyCode):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): key \(keyCode.rawValue, privacy: .public)"
            )
            try await driver.sendKey(keyCode, modifiers: [])

        case .shortcut(let keyCode, modifiers: let modifiers):
            let modNames = modifiers.map(\.rawValue).joined(separator: "+")
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): shortcut \(modNames, privacy: .public)+\(keyCode.rawValue, privacy: .public)"
            )
            try await driver.sendKey(keyCode, modifiers: modifiers)

        case .wait(let duration):
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): extra wait \(duration, privacy: .public)s"
            )
            try await Task.sleep(for: .seconds(duration))

        case .waitForText(let text, let timeout):
            guard let reader = screenReader else {
                Log.provision.warning(
                    "No screen reader — falling back to fixed delay for '\(text, privacy: .public)'"
                )
                try await Task.sleep(for: .seconds(timeout))
                return
            }
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): waiting for text '\(text, privacy: .public)'"
            )
            _ = try await reader.waitForText(text, timeout: timeout)

        case .clickText(let text, let timeout):
            guard let reader = screenReader else {
                Log.provision.warning(
                    "No screen reader — cannot click '\(text, privacy: .public)', skipping"
                )
                return
            }
            Log.provision.debug(
                "Step \(stepIndex + 1)/\(totalSteps): clicking text '\(text, privacy: .public)'"
            )
            let match: RecognizedText
            do {
                match = try await reader.waitForText(text, timeout: timeout)
            } catch {
                // `waitForText` already throws on a missing target —
                // this is not a silent failure. But its thrown
                // `ScreenReaderError.textNotFound` carries no
                // screenshot or OCR dump the way `expectScreen`'s
                // timeout does, so a clickText miss used to be a
                // *quieter* failure than a gate miss for the exact
                // same underlying problem (a stale/guessed label).
                // Bring it up to parity: save the same diagnostic
                // artifacts and surface the same
                // ``SetupAutomationExecutorError/screenGateTimedOut(stepIndex:totalSteps:expectedMarkers:actualTextExcerpt:timeout:artifactDirectory:)``
                // case `expectScreen` uses, with the single click
                // target as its one-element `expectedMarkers`.
                Log.provision.error(
                    "Step \(stepIndex + 1)/\(totalSteps): clickText target '\(text, privacy: .public)' not found — \(error.localizedDescription, privacy: .public)"
                )
                // Best-effort: `waitForText` doesn't hand back what it
                // last observed on failure, so re-poll once for the
                // diagnostic dump. A throw here would mask the real
                // (textNotFound) error, so failures fall back to an
                // empty observation rather than propagating.
                let observed = (try? await reader.recognizeText()) ?? []
                let artifactDirectory = await saveDiagnosticArtifacts(
                    to: diagnosticsDirectory,
                    stepIndex: stepIndex,
                    expectedMarkers: [text],
                    observed: observed,
                    screenReader: reader
                )
                throw SetupAutomationExecutorError.screenGateTimedOut(
                    stepIndex: stepIndex,
                    totalSteps: totalSteps,
                    expectedMarkers: [text],
                    actualTextExcerpt: excerpt(from: observed),
                    timeout: timeout,
                    artifactDirectory: artifactDirectory
                )
            }
            // Convert Vision bounding box (bottom-left origin, 0-1) to
            // view click coordinates (top-left origin, 0-1).
            let clickX = match.boundingBox.midX
            let clickY = 1.0 - match.boundingBox.midY
            try await driver.clickAt(x: clickX, y: clickY)

        case .expectScreen(let markers, let timeout):
            try await performExpectScreen(
                containsAny: markers,
                timeout: timeout,
                screenReader: screenReader,
                diagnosticsDirectory: diagnosticsDirectory,
                pollInterval: screenGatePollInterval,
                stepIndex: stepIndex,
                totalSteps: totalSteps
            )
        }
    }

    // MARK: - Screen Gates

    /// Polls the screen until one of `markers` appears, or captures
    /// diagnostics and throws once `timeout` elapses.
    ///
    /// Checks immediately on entry (no upfront sleep) so a screen
    /// that's already showing the expected marker resolves the gate
    /// at once — this is what makes gates net *faster* than the
    /// fixed delays they replace on a fast host, while still being
    /// able to wait the full `timeout` under load.
    ///
    /// - Parameters:
    ///   - markers: Candidate substrings; any one matching (case-
    ///     insensitive) satisfies the gate.
    ///   - timeout: Maximum seconds to wait before failing.
    ///   - screenReader: The screen reader to poll. When `nil`, falls
    ///     back to a fixed `timeout`-second delay and never fails —
    ///     matching `.waitForText`'s no-reader behavior.
    ///   - diagnosticsDirectory: Where to save failure artifacts.
    ///   - pollInterval: Seconds between polls.
    ///   - stepIndex: Zero-based step index, for logging and the
    ///     thrown error.
    ///   - totalSteps: Total step count, for logging and the thrown
    ///     error.
    /// - Throws: ``SetupAutomationExecutorError/screenGateTimedOut(stepIndex:totalSteps:expectedMarkers:actualTextExcerpt:timeout:artifactDirectory:)``
    ///   if no marker appears within `timeout`.
    @MainActor
    private static func performExpectScreen(
        containsAny markers: [String],
        timeout: TimeInterval,
        screenReader: (any ScreenReader)?,
        diagnosticsDirectory: URL?,
        pollInterval: TimeInterval,
        stepIndex: Int,
        totalSteps: Int
    ) async throws {
        guard let reader = screenReader else {
            Log.provision.warning(
                "No screen reader — falling back to fixed \(Int(timeout))s delay for screen gate \(stepIndex + 1)/\(totalSteps)"
            )
            try await Task.sleep(for: .seconds(timeout))
            return
        }

        let markerList = markers.joined(separator: ", ")
        Log.provision.info(
            "Step \(stepIndex + 1)/\(totalSteps): waiting for screen matching any of [\(markerList, privacy: .public)] (timeout: \(Int(timeout))s)"
        )
        let deadline = Date().addingTimeInterval(timeout)
        var lastObserved: [RecognizedText] = []

        while true {
            let observed = try await reader.recognizeText()
            lastObserved = observed
            if observed.contains(where: { region in
                markers.contains { region.text.localizedCaseInsensitiveContains($0) }
            }) {
                Log.provision.debug("Step \(stepIndex + 1)/\(totalSteps): screen gate satisfied")
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            try await Task.sleep(for: .seconds(min(pollInterval, remaining)))
        }

        Log.provision.error(
            "Step \(stepIndex + 1)/\(totalSteps): screen gate timed out waiting for [\(markerList, privacy: .public)]"
        )
        let artifactDirectory = await saveDiagnosticArtifacts(
            to: diagnosticsDirectory,
            stepIndex: stepIndex,
            expectedMarkers: markers,
            observed: lastObserved,
            screenReader: reader
        )
        throw SetupAutomationExecutorError.screenGateTimedOut(
            stepIndex: stepIndex,
            totalSteps: totalSteps,
            expectedMarkers: markers,
            actualTextExcerpt: excerpt(from: lastObserved),
            timeout: timeout,
            artifactDirectory: artifactDirectory
        )
    }

    /// Maximum length of the actual-text excerpt embedded in
    /// ``SetupAutomationExecutorError/screenGateTimedOut(stepIndex:totalSteps:expectedMarkers:actualTextExcerpt:timeout:artifactDirectory:)``'s
    /// message, so a screen full of dense text doesn't produce an
    /// unreadable error string. The full, untruncated dump is always
    /// saved to disk when a diagnostics directory is configured.
    private static let excerptCharacterLimit = 500

    /// Joins observed OCR text regions into a single truncated
    /// string for embedding directly in the thrown error's message.
    ///
    /// - Parameter observed: The text regions from the final poll
    ///   before timeout.
    /// - Returns: The joined text, truncated to
    ///   ``excerptCharacterLimit`` characters with a `"…"` suffix if
    ///   it was cut, or `"(no text recognized)"` if `observed` is empty.
    private static func excerpt(from observed: [RecognizedText]) -> String {
        guard !observed.isEmpty else { return "(no text recognized)" }
        let joined = observed.map(\.text).joined(separator: " | ")
        guard joined.count > excerptCharacterLimit else { return joined }
        return String(joined.prefix(excerptCharacterLimit)) + "…"
    }

    /// Saves a failure screenshot (when possible) and the full OCR
    /// dump for a timed-out screen gate.
    ///
    /// - Parameters:
    ///   - directory: The diagnostics directory, or `nil` to skip
    ///     saving entirely.
    ///   - stepIndex: Zero-based index of the failed step, used to
    ///     name the artifact files.
    ///   - expectedMarkers: The markers the gate was waiting for,
    ///     recorded in the dump for context.
    ///   - observed: Every OCR text region seen on the final poll
    ///     (`.fast`-level — see ``VZScreenReader``'s "Polling
    ///     Strategy" documentation). Used as the saved dump's content
    ///     only when `screenReader` can't do better; see
    ///     `dumpedText` below.
    ///   - screenReader: The screen reader that was polled — cast to
    ///     ``SpooktacularCore/ScreenshotCapturing`` when possible to
    ///     also save a PNG, and to
    ///     ``SpooktacularCore/AccurateTextCapturing`` when possible
    ///     to re-run OCR at `.accurate` for the saved dump.
    /// - Returns: `directory`, if artifacts were written there;
    ///   `nil` if `directory` was `nil` or the write failed.
    @MainActor
    private static func saveDiagnosticArtifacts(
        to directory: URL?,
        stepIndex: Int,
        expectedMarkers: [String],
        observed: [RecognizedText],
        screenReader: any ScreenReader
    ) async -> URL? {
        guard let directory else { return nil }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.provision.error(
                "Could not create diagnostics directory \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        let baseName = "automation-failure-step\(stepIndex + 1)"

        // The thrown error's own `actualTextExcerpt` (built by the
        // caller, `performExpectScreen`, from the same `observed`
        // value) stays at whatever level routine polling used —
        // cheap and already in hand. The *saved* dump is a forensic
        // artifact worth the extra Vision latency for: prefer one
        // fresh `.accurate` pass when the reader supports it,
        // falling back to the last poll's (`.fast`-level) `observed`
        // when it doesn't (e.g. mock readers in tests) or the pass
        // itself throws.
        var dumpedText = observed
        if let accurateReader = screenReader as? any AccurateTextCapturing {
            do {
                dumpedText = try await accurateReader.recognizeTextAccurate()
            } catch {
                Log.provision.warning(
                    "Accurate re-scan for diagnostics failed, using last poll's OCR instead: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        var dump = "Setup Assistant screen gate timed out at step \(stepIndex + 1).\n"
        dump += "Expected one of: \(expectedMarkers)\n\n"
        dump += "Observed OCR text (\(dumpedText.count) region(s)):\n"
        if dumpedText.isEmpty {
            dump += "(no text recognized)\n"
        } else {
            for region in dumpedText {
                dump += "- \(region.text)\n"
            }
        }

        let textURL = directory.appendingPathComponent("\(baseName).txt")
        do {
            try dump.write(to: textURL, atomically: true, encoding: .utf8)
            Log.provision.notice("Saved automation failure OCR dump to \(textURL.path, privacy: .public)")
        } catch {
            Log.provision.error(
                "Could not write OCR dump to \(textURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        if let capturing = screenReader as? any ScreenshotCapturing {
            do {
                if let pngData = try await capturing.capturePNG() {
                    let pngURL = directory.appendingPathComponent("\(baseName).png")
                    try pngData.write(to: pngURL)
                    Log.provision.notice("Saved automation failure screenshot to \(pngURL.path, privacy: .public)")
                }
            } catch {
                Log.provision.error(
                    "Could not capture/save failure screenshot: \(error.localizedDescription, privacy: .public)"
                )
                // Non-fatal: the OCR dump above already succeeded, and
                // that's the artifact that actually names what went
                // wrong. A missing screenshot shouldn't turn a
                // reported failure into a hard crash.
            }
        }

        return directory
    }
}
