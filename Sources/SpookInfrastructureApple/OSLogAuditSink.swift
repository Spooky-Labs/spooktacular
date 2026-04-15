import Foundation
import os
import SpookCore
import SpookApplication

/// Writes audit records to Apple's unified logging system.
///
/// Records are visible in Console.app and queryable via `log show`.
/// Use the predicate `subsystem == "com.spooktacular" AND category == "audit"`
/// to filter audit events.
public actor OSLogAuditSink: AuditSink {
    private let logger = Logger(subsystem: "com.spooktacular", category: "audit")

    public init() {}

    public func record(_ entry: AuditRecord) async {
        logger.notice("""
            AUDIT: \(entry.action, privacy: .public) \
            resource=\(entry.resource, privacy: .public) \
            actor=\(entry.actorIdentity, privacy: .public) \
            tenant=\(entry.tenant.rawValue, privacy: .public) \
            scope=\(entry.scope.rawValue, privacy: .public) \
            outcome=\(entry.outcome.rawValue, privacy: .public) \
            requestID=\(entry.correlationID ?? "-", privacy: .public) \
            id=\(entry.id, privacy: .public)
            """)
    }
}
