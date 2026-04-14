import AppKit
import os
import SpooktacularKit
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
/// 4. Results are mapped to ``RecognizedText`` values with bounding
///    boxes and confidence scores.
///
/// ## Polling Strategy
///
/// ``waitForText(_:timeout:)`` polls every 2 seconds, which balances
/// responsiveness with CPU usage. Setup Assistant screen transitions
/// typically take 1--5 seconds, so 2-second polling catches most
/// transitions within one poll cycle.
///
/// ## Thread Safety
///
/// All methods are `@MainActor` because `VZVirtualMachineView` and
/// `NSBitmapImageRep` must be accessed on the main thread.
@MainActor
final class VZScreenReader: ScreenReader {

    /// The VM view to capture.
    private let vmView: VZVirtualMachineView

    /// The polling interval for ``waitForText(_:timeout:)``.
    private let pollInterval: TimeInterval

    /// Creates a screen reader connected to the given VM view.
    ///
    /// - Parameters:
    ///   - vmView: The `VZVirtualMachineView` to capture for OCR.
    ///   - pollInterval: Seconds between screen captures when polling.
    ///     Defaults to 2 seconds.
    init(vmView: VZVirtualMachineView, pollInterval: TimeInterval = 2) {
        self.vmView = vmView
        self.pollInterval = pollInterval
    }

    // MARK: - ScreenReader

    func recognizeText() async throws -> [SpooktacularKit.RecognizedText] {
        // Capture the view as a CGImage.
        guard let bitmap = vmView.bitmapImageRepForCachingDisplay(in: vmView.bounds) else {
            Log.provision.warning("VZScreenReader: bitmapImageRepForCachingDisplay returned nil")
            return []
        }
        vmView.cacheDisplay(in: vmView.bounds, to: bitmap)
        guard let cgImage = bitmap.cgImage else {
            Log.provision.warning("VZScreenReader: bitmap has no CGImage")
            return []
        }

        // Run Vision OCR.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try handler.perform([request])

        guard let observations = request.results else {
            return []
        }

        let results = observations.compactMap { observation -> SpooktacularKit.RecognizedText? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            return SpooktacularKit.RecognizedText(
                text: candidate.string,
                boundingBox: observation.boundingBox,
                confidence: candidate.confidence
            )
        }

        Log.provision.debug(
            "VZScreenReader: recognized \(results.count) text region(s)"
        )
        return results
    }

    func waitForText(_ text: String, timeout: TimeInterval) async throws -> SpooktacularKit.RecognizedText {
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
}
