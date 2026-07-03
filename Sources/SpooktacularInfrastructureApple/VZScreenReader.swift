import AppKit
import SpooktacularCore
import Vision
@preconcurrency import Virtualization

/// Vision-based ``ScreenReader`` that captures the VM display and
/// recognizes text using Apple's OCR engine.
///
/// `VZScreenReader` captures the `VZVirtualMachineView` as a bitmap,
/// then runs a `VNRecognizeTextRequest` to extract all visible text.
/// This enables screen-aware Setup Assistant automation --- the
/// executor can wait for specific text to appear before proceeding,
/// replacing fixed timing delays with deterministic screen checks.
///
/// ## How It Works
///
/// 1. The view's `bitmapImageRepForCachingDisplay(in:)` creates a
///    bitmap representation of the current display contents.
/// 2. `cacheDisplay(in:to:)` renders the view into the bitmap.
/// 3. The bitmap's `CGImage` is passed to a Vision
///    `VNRecognizeTextRequest` with `.accurate` recognition level.
/// 4. Results are mapped to ``SpooktacularCore.RecognizedText`` values with bounding
///    boxes and confidence scores.
///
/// It also conforms to ``ScreenshotCapturing``, reusing the same
/// bitmap capture to hand back PNG data — `SetupAutomationExecutor`
/// uses this to save a screenshot alongside the OCR dump when a
/// screen gate times out. It further conforms to
/// ``AccurateTextCapturing`` for that same failure path's OCR dump —
/// see ``recognizeTextAccurate()``.
///
/// ## Polling Strategy
///
/// ``recognizeText()`` — used both by ``waitForText(_:timeout:)``'s
/// own poll loop and by `SetupAutomationExecutor`'s `expectScreen`
/// gate loop — runs on the main actor and blocks it for the duration
/// of each Vision request, every poll interval, for as long as a gate
/// is open (up to its timeout). Two choices keep that cost down
/// without weakening what a gate actually detects:
///
/// - **Recognition level: `.fast`.** Per Apple's documentation,
///   [`.fast`](https://developer.apple.com/documentation/vision/vnrequesttextrecognitionlevel/fast)
///   "returns results more quickly at the expense of accuracy" and is
///   "optimized for" real-time reading, while
///   [`.accurate`](https://developer.apple.com/documentation/vision/vnrequesttextrecognitionlevel/accurate)
///   "takes more time to produce a more comprehensive result." Every
///   string this project gates or clicks on (``BootAction/expectScreen(containsAny:timeout:)``,
///   ``BootAction/clickText(_:timeout:)``, ``BootAction/waitForText(_:timeout:)``)
///   is a whole word or short phrase of large, high-contrast Setup
///   Assistant/Terminal UI text — exactly the "real-time reading"
///   case `.fast` targets, not small or stylized text where the
///   accuracy gap matters. ``recognizeTextAccurate()`` still exists,
///   at `.accurate`, purely for the one-shot diagnostic capture a
///   timed-out gate saves to disk, where the extra latency is paid
///   once instead of every poll.
/// - **Poll interval: 3 seconds** (was 2). Setup Assistant screen
///   transitions typically take 1--5 seconds, so a 3-second cadence
///   still catches most transitions within one or two poll cycles
///   while cutting the number of main-actor-blocking Vision requests
///   issued over a long gate wait by a third relative to the previous
///   2-second cadence — meaningful given `.fast` is already the
///   cheaper level; the two changes compound rather than substitute
///   for each other.
///
/// ## Thread Safety
///
/// All methods are `@MainActor` because `VZVirtualMachineView` and
/// `NSBitmapImageRep` must be accessed on the main thread.
@MainActor
public final class VZScreenReader: ScreenReader, ScreenshotCapturing, AccurateTextCapturing {

    /// The VM view to capture.
    private let vmView: VZVirtualMachineView

    /// The polling interval for ``waitForText(_:timeout:)``.
    private let pollInterval: TimeInterval

    /// Creates a screen reader connected to the given VM view.
    ///
    /// - Parameters:
    ///   - vmView: The `VZVirtualMachineView` to capture for OCR.
    ///   - pollInterval: Seconds between screen captures when polling.
    ///     Defaults to 3 seconds — see this type's "Polling Strategy"
    ///     documentation for why.
    public init(vmView: VZVirtualMachineView, pollInterval: TimeInterval = 3) {
        self.vmView = vmView
        self.pollInterval = pollInterval
    }

    // MARK: - Shared Capture

    /// Renders the VM view into a fresh `NSBitmapImageRep`.
    ///
    /// Shared by ``recognizeText()`` (which needs a `CGImage` for
    /// Vision) and ``capturePNG()`` (which needs PNG-encodable
    /// bitmap data) so both draw from the exact same capture call
    /// rather than duplicating the `bitmapImageRepForCachingDisplay` /
    /// `cacheDisplay` pair.
    ///
    /// - Returns: The rendered bitmap, or `nil` if the view couldn't
    ///   be captured.
    private func captureBitmap() -> NSBitmapImageRep? {
        guard let bitmap = vmView.bitmapImageRepForCachingDisplay(in: vmView.bounds) else {
            Log.provision.warning("VZScreenReader: bitmapImageRepForCachingDisplay returned nil")
            return nil
        }
        vmView.cacheDisplay(in: vmView.bounds, to: bitmap)
        return bitmap
    }

    // MARK: - ScreenReader

    /// Captures the VM's current display and recognizes every
    /// visible text region via Vision OCR, at the given recognition
    /// level.
    ///
    /// Shared implementation behind ``recognizeText()`` (`.fast`,
    /// used for routine polling) and ``recognizeTextAccurate()``
    /// (`.accurate`, used for one-shot diagnostic capture) — see this
    /// type's "Polling Strategy" documentation for why they differ.
    ///
    /// - Parameter level: The Vision recognition level to request.
    /// - Returns: Recognized text regions with bounding boxes and
    ///   confidence scores, or an empty array if the view couldn't
    ///   be captured.
    private func recognizeText(
        level: VNRequestTextRecognitionLevel
    ) async throws -> [SpooktacularCore.RecognizedText] {
        guard let bitmap = captureBitmap() else {
            // captureBitmap() already logged the specific reason.
            return []
        }
        guard let cgImage = bitmap.cgImage else {
            Log.provision.warning("VZScreenReader: bitmap has no CGImage")
            return []
        }

        // Run Vision OCR.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])

        guard let observations = request.results else {
            return []
        }

        let results = observations.compactMap { observation -> SpooktacularCore.RecognizedText? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let bbox = observation.boundingBox
            return SpooktacularCore.RecognizedText(
                text: candidate.string,
                boundingBox: NormalizedRect(
                    x: Double(bbox.origin.x),
                    y: Double(bbox.origin.y),
                    width: Double(bbox.width),
                    height: Double(bbox.height)
                ),
                confidence: candidate.confidence
            )
        }

        Log.provision.debug(
            "VZScreenReader: recognized \(results.count) text region(s) at \(String(describing: level), privacy: .public) level"
        )
        return results
    }

    /// Captures the VM's current display and recognizes every
    /// visible text region via Vision OCR at `.fast` recognition —
    /// see this type's "Polling Strategy" documentation for why.
    ///
    /// - Returns: Recognized text regions with bounding boxes and
    ///   confidence scores, or an empty array if the view couldn't
    ///   be captured.
    public func recognizeText() async throws -> [SpooktacularCore.RecognizedText] {
        try await recognizeText(level: .fast)
    }

    // MARK: - AccurateTextCapturing

    /// Captures the VM's current display and recognizes every
    /// visible text region via Vision OCR at `.accurate` recognition
    /// — reserved for the one-shot diagnostic capture a timed-out
    /// screen gate saves to disk (see ``AccurateTextCapturing``'s
    /// documentation). Routine polling uses ``recognizeText()``'s
    /// cheaper `.fast` level instead.
    ///
    /// - Returns: Recognized text regions with bounding boxes and
    ///   confidence scores, or an empty array if the view couldn't
    ///   be captured.
    public func recognizeTextAccurate() async throws -> [SpooktacularCore.RecognizedText] {
        try await recognizeText(level: .accurate)
    }

    /// Polls the VM's display every ``pollInterval`` seconds until
    /// `text` appears, or throws once `timeout` elapses.
    ///
    /// - Parameters:
    ///   - text: The text to search for (case-insensitive substring
    ///     match).
    ///   - timeout: Maximum seconds to wait.
    /// - Returns: The matching ``SpooktacularCore.RecognizedText``.
    /// - Throws: ``ScreenReaderError/textNotFound(_:timeout:)`` if
    ///   `text` never appears within `timeout`.
    public func waitForText(_ text: String, timeout: TimeInterval) async throws -> SpooktacularCore.RecognizedText {
        let deadline = Date().addingTimeInterval(timeout)
        Log.provision.info(
            "VZScreenReader: waiting for '\(text, privacy: .public)' (timeout: \(Int(timeout))s)"
        )

        while Date() < deadline {
            let results = try await recognizeText()
            if let match = results.first(where: {
                $0.text.localizedCaseInsensitiveContains(text)
            }) {
                Log.provision.info(
                    "VZScreenReader: found '\(text, privacy: .public)' at (\(match.boundingBox.midX), \(match.boundingBox.midY)) confidence: \(match.confidence)"
                )
                return match
            }
            try await Task.sleep(for: .seconds(pollInterval))
        }

        Log.provision.error(
            "VZScreenReader: '\(text, privacy: .public)' not found within \(Int(timeout))s"
        )
        throw ScreenReaderError.textNotFound(text, timeout: timeout)
    }

    // MARK: - ScreenshotCapturing

    /// Captures the VM's current display as PNG data.
    ///
    /// Reuses the same `bitmapImageRepForCachingDisplay` /
    /// `cacheDisplay` capture ``recognizeText()`` performs (via
    /// ``captureBitmap()``), then asks `NSBitmapImageRep` for a PNG
    /// representation — no separate rendering pass.
    ///
    /// - Returns: PNG-encoded image data, or `nil` if the view
    ///   couldn't be captured or PNG encoding failed.
    public func capturePNG() async throws -> Data? {
        guard let bitmap = captureBitmap() else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
