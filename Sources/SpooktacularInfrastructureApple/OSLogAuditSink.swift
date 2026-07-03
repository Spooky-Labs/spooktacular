import Foundation
import os
import SpooktacularCore
import SpooktacularApplication

/// Writes audit records to Apple's unified logging system.
///
/// Records are visible in Console.app and queryable via `log show`.
/// Use the predicate `subsystem == "com.spooktacular" AND category == "audit"`
/// to filter audit events.
///
/// `Sendable final class` rather than `actor` because the
/// only state is a `Logger`, which is `Sendable` per Apple's
/// docs (`os.Logger` conforms to `Sendable`,
/// `SendableMetatype`).  No mutation, no cross-call
/// coordination — an actor would force an unnecessary
/// executor hop per record.
public final class OSLogAuditSink: AuditSink {
    private let logger = Logger(subsystem: "com.spooktacular", category: "audit")

    public init() {}

    public func record(_ entry: AuditRecord) async throws {
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
