import Foundation

/// In-memory directory of enrolled devices, keyed by UDID.
///
/// Updated by the embedded MDM's check-in handler — each
/// `Authenticate` call inserts / refreshes a record, each
/// `TokenUpdate` updates push-token metadata, each `CheckOut`
/// marks the record `checkedOut` (kept around for audit but
/// no longer surfaces in ``allEnrolled()``).
///
/// ## Persistence (intentionally absent for now)
///
/// MVP keeps all state in memory. Process restarts wipe the
/// directory; enrolled VMs naturally re-`Authenticate` on
/// their next boot, so the lossy semantics are fine for the
/// single-host EC2 Mac runner case. A JSON-backed snapshotter
/// can layer on later without changing this actor's API —
/// `record(forUDID:)` + `allEnrolled()` are the only read
/// paths and they're already async, so a future implementation
/// can transparently hit disk.
///
/// ## Why an actor rather than a `[String: Record]` dict
///
/// Concurrent traffic from multiple in-flight enrollments is
/// the common case. An actor gives us serialised mutation
/// without sprinkling locks across call sites, and matches the
/// shape of `HTTPAPIServer` and the rest of the app's
/// concurrency model.
public actor MDMDeviceStore {

    // MARK: - Types

    /// One enrolled-device record. Snapshot value type.
    public struct Record: Sendable, Equatable {

        /// Device UDID — primary key in the store.
        public let udid: String

        /// MDM topic from the device's `Authenticate`. Should
        /// match the topic in the enrollment profile we
        /// generated for this VM. A mismatch indicates the VM
        /// was re-enrolled into a different MDM and stale data
        /// is in our store.
        public let topic: String

        /// Hardware model identifier as the device reports it
        /// (e.g. `VirtualMac2,1`). Optional — `Authenticate`
        /// MAY include this but isn't required to.
        public let model: String?

        /// macOS version the device was running at most-recent
        /// `Authenticate`. Optional.
        public let osVersion: String?

        /// APNs push token from the most-recent `TokenUpdate`.
        /// We don't use APNs (poll-only design — see Phase 5
        /// in plan) but persist it for diagnostic completeness
        /// and to enable a future opt-in.
        public let pushToken: Data?

        /// Push-magic string Apple's `mdmclient` uses to
        /// validate APNs payloads. See ``pushToken`` rationale.
        public let pushMagic: String?

        /// When the device first authenticated.
        public let firstSeen: Date

        /// When the device last sent any check-in or response.
        /// Updated by every check-in + every command response.
        /// Used for fleet-health UIs and stale-record GC.
        public let lastSeen: Date

        /// `true` once the device sent a `CheckOut`. Records
        /// stay in the store post-checkOut so audit retains
        /// continuity, but ``MDMDeviceStore/allEnrolled()``
        /// hides them.
        public let checkedOut: Bool

        public init(
            udid: String,
            topic: String,
            model: String?,
            osVersion: String?,
            pushToken: Data?,
            pushMagic: String?,
            firstSeen: Date,
            lastSeen: Date,
            checkedOut: Bool
        ) {
            self.udid = udid
            self.topic = topic
            self.model = model
            self.osVersion = osVersion
            self.pushToken = pushToken
            self.pushMagic = pushMagic
            self.firstSeen = firstSeen
            self.lastSeen = lastSeen
            self.checkedOut = checkedOut
        }
    }

    // MARK: - State

    private var records: [String: Record] = [:]

    /// Wall-clock provider. Injectable so tests can pin it for
    /// determinism without monkey-patching `Date()`.
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Mutators

    /// Inserts or refreshes a record from an `Authenticate`
    /// message. If the device was previously checked-out, the
    /// `checkedOut` flag is cleared (the device re-enrolled).
    public func upsertAuthenticate(
        _ message: MDMCheckInMessage.Authenticate
    ) {
        let existing = records[message.udid]
        let record = Record(
            udid: message.udid,
            topic: message.topic,
            model: message.model ?? existing?.model,
            osVersion: message.osVersion ?? existing?.osVersion,
            pushToken: existing?.pushToken,
            pushMagic: existing?.pushMagic,
            firstSeen: existing?.firstSeen ?? now(),
            lastSeen: now(),
            checkedOut: false
        )
        records[message.udid] = record
    }

    /// Layers `TokenUpdate` fields onto the existing record.
    /// If we somehow receive `TokenUpdate` before
    /// `Authenticate` (shouldn't happen per Apple's docs but
    /// `mdmclient` ordering is empirically loose), we
    /// fabricate a partial record so the data isn't lost.
    public func upsertTokenUpdate(
        _ message: MDMCheckInMessage.TokenUpdate
    ) {
        let existing = records[message.udid]
        records[message.udid] = Record(
            udid: message.udid,
            topic: message.topic,
            model: existing?.model,
            osVersion: existing?.osVersion,
            pushToken: message.pushToken ?? existing?.pushToken,
            pushMagic: message.pushMagic ?? existing?.pushMagic,
            firstSeen: existing?.firstSeen ?? now(),
            lastSeen: now(),
            checkedOut: existing?.checkedOut ?? false
        )
    }

    /// Marks the record `checkedOut`. The record itself stays
    /// in the store so audit reports retain continuity for the
    /// device's lifecycle — only ``allEnrolled()`` hides it.
    public func markCheckedOut(_ udid: String) {
        guard let existing = records[udid] else { return }
        records[udid] = Record(
            udid: existing.udid,
            topic: existing.topic,
            model: existing.model,
            osVersion: existing.osVersion,
            pushToken: existing.pushToken,
            pushMagic: existing.pushMagic,
            firstSeen: existing.firstSeen,
            lastSeen: now(),
            checkedOut: true
        )
    }

    /// Bumps `lastSeen` to now. Called from the command-poll
    /// path so a device polling without sending check-in
    /// messages still keeps its liveness signal fresh.
    public func touchLastSeen(_ udid: String) {
        guard let existing = records[udid] else { return }
        records[udid] = Record(
            udid: existing.udid,
            topic: existing.topic,
            model: existing.model,
            osVersion: existing.osVersion,
            pushToken: existing.pushToken,
            pushMagic: existing.pushMagic,
            firstSeen: existing.firstSeen,
            lastSeen: now(),
            checkedOut: existing.checkedOut
        )
    }

    // MARK: - Readers

    /// Returns the record for the given UDID, or `nil` if the
    /// device has never enrolled.
    public func record(forUDID udid: String) -> Record? {
        records[udid]
    }

    /// All currently-enrolled (i.e. not checked-out) records,
    /// sorted by UDID for deterministic iteration order. Used
    /// by the operator UI / CLI.
    public func allEnrolled() -> [Record] {
        records.values
            .filter { !$0.checkedOut }
            .sorted { $0.udid < $1.udid }
    }

    /// Total record count including checked-out devices.
    public var count: Int {
        records.count
    }
}
