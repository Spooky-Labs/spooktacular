// No imports — stdlib only. Deliberately avoids importing Foundation
// so ``NormalizedRect`` stays a pure value type with no dependency on
// CoreGraphics `CGRect` (which the adapter layer converts from/to).
import Foundation

/// A rectangle in normalized coordinates (0…1 on both axes).
///
/// Used by ``RecognizedText`` to describe OCR bounding boxes in a
/// framework-independent form. Vision framework's coordinate
/// convention is origin-bottom-left — callers converting to view
/// coordinates must flip the y axis as `viewY = 1 - midY`.
public struct NormalizedRect: Sendable, Equatable, Hashable {

    /// X coordinate of the origin corner in the 0…1 range.
    public let x: Double

    /// Y coordinate of the origin corner in the 0…1 range.
    public let y: Double

    /// Width in the 0…1 range.
    public let width: Double

    /// Height in the 0…1 range.
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// X coordinate of the centre of the rectangle.
    public var midX: Double { x + width / 2 }

    /// Y coordinate of the centre of the rectangle.
    public var midY: Double { y + height / 2 }
}

/// Reads text from a virtual machine's display.
///
/// Implement this protocol to provide screen capture and OCR
/// for screen-aware Setup Assistant automation. The screen reader
/// enables the automation executor to wait for specific text to
/// appear on the VM display before proceeding, replacing fixed
/// timing delays with deterministic screen state checks.
///
/// ## Design
///
/// This follows the approach used by
/// [Tart's Packer plugin](https://github.com/cirruslabs/tart),
/// which uses Apple's Vision framework to recognize text on the
/// VM screen and drive Setup Assistant navigation based on what
/// is actually visible rather than elapsed time.
///
/// ## Architecture
///
/// The protocol lives in SpooktacularKit (no AppKit or Vision
/// imports) so it can be referenced from any target. The concrete
/// implementation (`VZScreenReader`) lives in the `spook` CLI
/// target where AppKit and Vision are available.
///
/// ## Example
///
/// ```swift
/// let reader: ScreenReader = VZScreenReader(vmView: view)
/// let match = try await reader.waitForText("Continue", timeout: 60)
/// print("Found '\(match.text)' at \(match.boundingBox)")
/// ```
public protocol ScreenReader: Sendable {

    /// Captures the current screen and returns all recognized text
    /// with bounding boxes.
    ///
    /// Each recognized text region includes the string content, a
    /// normalized bounding box (0--1 range, origin at bottom-left
    /// per Vision convention), and a confidence score.
    ///
    /// - Returns: An array of ``RecognizedText`` values, one per
    ///   recognized text region. May be empty if no text is visible
    ///   or the screen capture fails.
    @MainActor func recognizeText() async throws -> [RecognizedText]

    /// Waits until the specified text appears on screen, with timeout.
    ///
    /// Polls the screen at regular intervals (implementation-defined)
    /// until a recognized text region contains the search string
    /// (case-insensitive). Returns the first match found.
    ///
    /// - Parameters:
    ///   - text: The text to search for (case-insensitive substring match).
    ///   - timeout: Maximum time in seconds to wait before throwing.
    /// - Returns: The ``RecognizedText`` that matched.
    /// - Throws: ``ScreenReaderError/textNotFound(_:timeout:)`` if the
    ///   text does not appear within the timeout.
    @MainActor func waitForText(_ text: String, timeout: TimeInterval) async throws -> RecognizedText
}

/// A piece of text recognized on the VM screen.
///
/// Returned by ``ScreenReader/recognizeText()`` and
/// ``ScreenReader/waitForText(_:timeout:)``. Each instance
/// represents a single text observation from Apple's Vision
/// framework OCR.
public struct RecognizedText: Sendable {

    /// The recognized string.
    public let text: String

    /// Normalized bounding box (0--1 range, origin at bottom-left
    /// per Vision convention).
    ///
    /// To convert to view coordinates (top-left origin), flip the
    /// y-axis: `viewY = 1.0 - boundingBox.midY`.
    public let boundingBox: NormalizedRect

    /// Recognition confidence (0--1).
    ///
    /// Higher values indicate greater confidence in the recognized
    /// text. Values above 0.5 are generally reliable for UI text.
    public let confidence: Float

    /// Creates a recognized text value.
    ///
    /// - Parameters:
    ///   - text: The recognized string.
    ///   - boundingBox: Normalized bounding box (0--1, bottom-left origin).
    ///   - confidence: Recognition confidence (0--1).
    public init(text: String, boundingBox: NormalizedRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Errors that can occur during screen reading operations.
public enum ScreenReaderError: Error, Sendable, LocalizedError {

    /// The specified text was not found on screen within the timeout.
    ///
    /// - Parameters:
    ///   - text: The text that was searched for.
    ///   - timeout: The timeout in seconds that elapsed.
    case textNotFound(String, timeout: TimeInterval)

    /// A human-readable description of the error.
    public var errorDescription: String? {
        switch self {
        case .textNotFound(let text, let timeout):
            "Text '\(text)' not found on screen within \(Int(timeout)) seconds."
        }
    }

    /// A suggestion for how to recover from the error.
    public var recoverySuggestion: String? {
        switch self {
        case .textNotFound:
            "The VM screen may not have advanced to the expected state. Check the VM display manually."
        }
    }
}
