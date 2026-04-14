import Foundation

/// Abstracts logging so inner layers (Entities, Use Cases) don't import `os`.
///
/// The ``OSLogProvider`` in the Infrastructure layer provides the concrete
/// implementation using Apple's `os.Logger`. Tests can inject a silent or
/// capturing provider.
///
/// ## Clean Architecture
///
/// Logging is a cross-cutting concern. By defining it as a protocol in
/// the Interfaces layer, use cases can log without depending on any
/// framework. The Infrastructure layer provides the real implementation.
public protocol LogProvider: Sendable {
    func debug(_ message: String)
    func info(_ message: String)
    func notice(_ message: String)
    func warning(_ message: String)
    func error(_ message: String)
}

/// A no-op logger that discards all messages.
///
/// Used as the default when no logger is injected, and in tests
/// where log output would be noise.
public struct SilentLogProvider: LogProvider {
    public init() {}
    public func debug(_ message: String) {}
    public func info(_ message: String) {}
    public func notice(_ message: String) {}
    public func warning(_ message: String) {}
    public func error(_ message: String) {}
}
