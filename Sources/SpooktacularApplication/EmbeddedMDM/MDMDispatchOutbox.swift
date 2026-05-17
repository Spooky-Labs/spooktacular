import Foundation
import os

/// File-backed inbox for cross-process command dispatch.
///
/// ## Why a file-backed outbox
///
/// `spook mdm serve` (a long-running daemon) and `spook mdm
/// run` (a one-shot CLI invocation from another shell) need
/// to exchange dispatch requests without sharing memory. The
/// simplest sandbox-friendly IPC is a shared directory: the
/// CLI writes a JSON file describing the request; the serve
/// process polls the directory, builds the pkg, enqueues the
/// command, and deletes the file.
///
/// One-file-per-request keeps the protocol atomic — file
/// `write(.atomic)` + `rename(2)` give us all-or-nothing
/// semantics for free. No locking, no half-written reads.
///
/// ## Layout
///
/// ```
/// ~/.spooktacular/mdm/state/outbox/
///   <command-uuid>.json
///   <command-uuid>.json
/// ```
///
/// Each file is a self-contained `Request` JSON. The serve
/// process moves the contents through ``MDMUserDataDispatcher``
/// and removes the file on success. On failure, the file is
/// renamed to `<uuid>.failed.json` for operator inspection.
public actor MDMDispatchOutbox {

    // MARK: - Wire shape

    /// JSON shape on disk. Versioned via `schemaVersion` so we
    /// can evolve the format without breaking already-queued
    /// requests.
    public struct Request: Codable, Sendable, Equatable {
        /// Bump on backwards-incompatible changes. Reader
        /// rejects unknown versions to fail loud rather than
        /// silently misinterpret.
        public let schemaVersion: Int

        /// Command UUID the dispatcher will use when
        /// enqueuing. Pre-minted by the CLI so the operator
        /// can correlate logs across both processes.
        public let commandUUID: UUID

        /// Target VM's UDID — the dispatcher routes to this
        /// device's queue.
        public let udid: String

        /// Human-readable script filename for diagnostics +
        /// audit. Doesn't affect execution.
        public let scriptName: String

        /// Base64-encoded script bytes. Keeps the JSON
        /// readable and avoids escape headaches with embedded
        /// quotes / shell metacharacters.
        public let scriptBodyBase64: String

        public init(
            commandUUID: UUID = UUID(),
            udid: String,
            scriptName: String,
            scriptBody: Data
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.commandUUID = commandUUID
            self.udid = udid
            self.scriptName = scriptName
            self.scriptBodyBase64 = scriptBody.base64EncodedString()
        }

        /// Decoded script bytes. Returns nil if the base64 is
        /// malformed — reader treats that as a parse failure.
        public var scriptBody: Data? {
            Data(base64Encoded: scriptBodyBase64)
        }

        static let currentSchemaVersion = 1
    }

    // MARK: - State

    public nonisolated let directory: URL
    private let logger: Logger

    public init(
        directory: URL,
        logger: Logger = Logger(
            subsystem: "com.spookylabs.spooktacular",
            category: "mdm.outbox"
        )
    ) {
        self.directory = directory
        self.logger = logger
    }

    // MARK: - Submit (CLI side)

    /// Writes a request to the outbox. Atomic — readers never
    /// see a half-written file. Returns the request that was
    /// written (with its minted commandUUID).
    public func submit(_ request: Request) throws -> Request {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("\(request.commandUUID.uuidString).json")
        let data = try Self.encoder.encode(request)
        try data.write(to: url, options: .atomic)
        logger.notice(
            "Outbox: queued \(request.commandUUID.uuidString, privacy: .public) for UDID=\(request.udid, privacy: .public)"
        )
        return request
    }

    // MARK: - Drain (serve side)

    /// Reads every pending file in the outbox and hands it to
    /// `process`. The closure returns `true` on a successful
    /// dispatch (file is deleted) or `false` to defer (file
    /// stays).
    ///
    /// Files that fail to decode are renamed to
    /// `<uuid>.failed.json` so operator can inspect them
    /// without them looping forever.
    public func drain(
        _ process: (Request) async -> DrainOutcome
    ) async {
        let fm = FileManager.default
        let pending: [URL]
        do {
            pending = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".failed.") }
        } catch CocoaError.fileReadNoSuchFile {
            // Outbox directory not yet created — nothing to do.
            return
        } catch {
            logger.error("Outbox scan failed: \(String(describing: error), privacy: .public)")
            return
        }

        for fileURL in pending.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let data: Data
            do {
                data = try Data(contentsOf: fileURL)
            } catch {
                logger.error("Outbox read failed for \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                continue
            }
            let request: Request
            do {
                request = try Self.decoder.decode(Request.self, from: data)
                guard request.schemaVersion == Request.currentSchemaVersion else {
                    throw OutboxError.unsupportedSchema(version: request.schemaVersion)
                }
                guard request.scriptBody != nil else {
                    throw OutboxError.malformedScriptBody
                }
            } catch {
                logger.error(
                    "Outbox parse failed for \(fileURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public). Renaming to .failed.json"
                )
                let failed = fileURL
                    .deletingPathExtension()
                    .appendingPathExtension("failed.json")
                try? fm.moveItem(at: fileURL, to: failed)
                continue
            }

            let outcome = await process(request)
            switch outcome {
            case .delivered:
                try? fm.removeItem(at: fileURL)
            case .deferred:
                // Leave the file in place for the next drain cycle.
                break
            case .failed(let reason):
                logger.error(
                    "Outbox dispatch failed for \(request.commandUUID.uuidString, privacy: .public): \(reason, privacy: .public)"
                )
                let failed = fileURL
                    .deletingPathExtension()
                    .appendingPathExtension("failed.json")
                try? fm.moveItem(at: fileURL, to: failed)
            }
        }
    }

    // MARK: - Helpers

    /// Lists outbox contents — useful for diagnostics (`spook
    /// mdm outbox` or doctor).
    public func pendingCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.contains(".failed.") }
            .count
    }

    // MARK: - Wire encoders

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder = JSONDecoder()
}

/// Result of one outbox-drain dispatch attempt.
public enum DrainOutcome: Sendable {
    /// The request was successfully turned into an in-flight
    /// MDM command. The outbox deletes the file.
    case delivered

    /// The request couldn't be dispatched right now (e.g.
    /// target VM not yet enrolled). Leave the file in place
    /// for the next poll cycle.
    case deferred

    /// The request can't ever succeed (e.g. permanent build
    /// failure). The file is renamed to `.failed.json` for
    /// operator inspection.
    case failed(reason: String)
}

public enum OutboxError: Error, Sendable, Equatable {
    case unsupportedSchema(version: Int)
    case malformedScriptBody
}
