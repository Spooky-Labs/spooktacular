import Foundation
import SpookCore
import SpookApplication
import os

/// Concrete ``LogProvider`` using Apple's `os.Logger`.
///
/// This is the production implementation. Messages are visible in
/// Console.app and queryable via `log show`.
public struct OSLogProvider: LogProvider {
    private let logger: Logger

    /// Creates a logger with the given subsystem and category.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem identifier (e.g., `"com.spooktacular"`).
    ///   - category: The log category (e.g., `"clone"`, `"recycle"`).
    public init(subsystem: String = "com.spooktacular", category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
    public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
    public func notice(_ message: String) { logger.notice("\(message, privacy: .public)") }
    public func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
    public func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
