import Foundation

/// Per-UDID FIFO of pending ``MDMCommand`` deliveries with
/// in-flight tracking.
///
/// ## Wire model
///
/// MDM is a strict request/response loop: a device polls
/// `/mdm/server`, the server returns at most one command, the
/// device executes + acks, then polls again. There's never
/// more than one command in flight to any given device.
///
/// This actor models that:
///
/// - **Pending queue**: `[MDMCommand]` per UDID, FIFO-ordered.
/// - **In-flight slot**: at most one ``MDMCommand`` per UDID
///   that's been dequeued but not yet ack'd.
///
/// ``dequeueNext(forUDID:)`` returns the in-flight command if
/// one exists (re-delivery) — only when the slot is empty
/// does it consume from the pending queue.
///
/// On `Acknowledged` / `Error`: the in-flight command is
/// cleared (the queue moves on).
/// On `NotNow`: the in-flight slot stays put — the device is
/// busy and will retry the same command next poll.
/// On `Idle`: irrelevant to this actor — it means the device
/// has nothing to ack; the transport just dispatches a fresh
/// command via ``dequeueNext(forUDID:)``.
///
/// ## Persistence (intentionally absent)
///
/// MVP keeps everything in memory. After a host restart, any
/// in-flight commands are lost — devices retry their last
/// poll, get a fresh empty response (Idle) or a re-enqueued
/// command, and life continues. Persisting the queue is a
/// later phase; this actor's API stays stable.
public actor MDMCommandQueue {

    // MARK: - State

    private struct PerDevice {
        var pending: [MDMCommand] = []
        var inFlight: MDMCommand?
    }

    private var devices: [String: PerDevice] = [:]

    public init() {}

    // MARK: - Mutators

    /// Append a command to the device's pending queue. Order
    /// matters — commands deliver FIFO.
    public func enqueue(_ command: MDMCommand, forUDID udid: String) {
        var per = devices[udid] ?? PerDevice()
        per.pending.append(command)
        devices[udid] = per
    }

    /// Returns the next command to send to the device:
    /// the in-flight slot if it's occupied (re-delivery), else
    /// pop from the pending queue and move it into in-flight.
    /// Returns `nil` when both are empty.
    ///
    /// Side effects: the returned command is *always* in the
    /// in-flight slot afterwards. Callers must subsequently
    /// invoke ``acknowledge(commandUUID:forUDID:)`` or
    /// ``markFailed(commandUUID:forUDID:)`` to clear the slot
    /// — otherwise it gets re-delivered on the next poll.
    public func dequeueNext(forUDID udid: String) -> MDMCommand? {
        var per = devices[udid] ?? PerDevice()
        if let inFlight = per.inFlight {
            return inFlight
        }
        guard !per.pending.isEmpty else {
            // Persist the (still-empty) record so subsequent
            // operations don't constantly re-create it.
            devices[udid] = per
            return nil
        }
        let next = per.pending.removeFirst()
        per.inFlight = next
        devices[udid] = per
        return next
    }

    /// Clears the in-flight slot when the device acknowledges
    /// the command. No-op if the UUID doesn't match the
    /// current in-flight (Apple's `mdmclient` never sends an
    /// ack for a different command, but the transport layer
    /// shouldn't crash if it ever happens).
    public func acknowledge(commandUUID: UUID, forUDID udid: String) {
        guard var per = devices[udid] else { return }
        guard per.inFlight?.commandUUID == commandUUID else { return }
        per.inFlight = nil
        devices[udid] = per
    }

    /// Clears the in-flight slot on a permanent failure (the
    /// device returned `Status=Error`). Same correlation rules
    /// as ``acknowledge(commandUUID:forUDID:)``.
    public func markFailed(commandUUID: UUID, forUDID udid: String) {
        // Treated identically to acknowledge for the queue's
        // purposes — both outcomes mean "this command is
        // done, advance." The handler is responsible for
        // surfacing the error via audit + alerting; we just
        // make room for the next command.
        acknowledge(commandUUID: commandUUID, forUDID: udid)
    }

    /// Wipes a device's queue entirely (pending + in-flight).
    /// Called when a `CheckOut` arrives — the device removed
    /// the MDM profile, so anything we still had queued is
    /// undeliverable.
    public func removeAll(forUDID udid: String) {
        devices[udid] = nil
    }

    // MARK: - Readers

    /// Pending commands for the device, NOT including the
    /// in-flight slot. Used by the operator UI / CLI for
    /// "what's queued?" displays.
    public func pending(forUDID udid: String) -> [MDMCommand] {
        devices[udid]?.pending ?? []
    }

    /// The currently-in-flight command for the device, if any.
    /// `nil` when the slot is empty.
    public func inFlight(forUDID udid: String) -> MDMCommand? {
        devices[udid]?.inFlight
    }

    /// Total queued commands across all devices, useful for
    /// metrics gauges.
    public var totalPendingCount: Int {
        devices.values.reduce(0) { $0 + $1.pending.count }
    }
}
