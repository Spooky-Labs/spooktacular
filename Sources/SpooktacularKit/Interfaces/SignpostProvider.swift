import Foundation

/// Abstracts performance signposting for lifecycle tracing.
///
/// Use ``beginInterval(_:)`` at the start of an operation and
/// ``endInterval(_:)`` at the end. The Infrastructure layer
/// provides ``OSSignpostProvider`` using Apple's `OSSignposter`.
///
/// ## Clean Architecture
///
/// Signposting is a cross-cutting concern. By defining it as a protocol
/// in the Interfaces layer, use cases can emit signposts without
/// depending on the `os` framework. The Infrastructure layer provides
/// the real implementation.
public protocol SignpostProvider: Sendable {
    /// Begins a named timing interval. Returns an opaque ID.
    ///
    /// - Parameter name: A human-readable label for the interval
    ///   (e.g., `"clone"`, `"boot"`, `"ssh-ready"`).
    /// - Returns: An opaque identifier that must be passed to
    ///   ``endInterval(_:id:)`` to close this interval.
    func beginInterval(_ name: String) -> UInt64

    /// Ends a previously started interval.
    ///
    /// - Parameters:
    ///   - name: The same label passed to ``beginInterval(_:)``.
    ///   - id: The opaque identifier returned by ``beginInterval(_:)``.
    func endInterval(_ name: String, id: UInt64)

    /// Emits a point-in-time event (not an interval).
    ///
    /// - Parameter name: A human-readable label for the event
    ///   (e.g., `"cleanup-failure"`).
    func event(_ name: String)
}

/// A no-op signpost provider for tests and non-macOS platforms.
///
/// Every method is a no-op, making this safe to inject anywhere
/// without incurring runtime overhead or requiring `os` imports.
public struct SilentSignpostProvider: SignpostProvider {
    public init() {}
    public func beginInterval(_ name: String) -> UInt64 { 0 }
    public func endInterval(_ name: String, id: UInt64) {}
    public func event(_ name: String) {}
}
