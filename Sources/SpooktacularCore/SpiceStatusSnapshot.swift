import Foundation

/// Current state of the guest's SPICE clipboard bridge —
/// pushed from guest to host as a ``GuestEvent/spiceStatus(_:)``
/// frame over the vsock event channel (see
/// `AgentEventListener`), decoded by the host's workspace
/// toolbar to pick a tri-state pill color.
///
/// Lives in ``SpooktacularCore`` because BOTH sides of the
/// wire need to encode/decode it: the Guest Tools app produces
/// the payload, the host's `AgentEventListener` consumes it.
/// Keeping the DTO in Core avoids forcing the host to import a
/// guest-side library just to name the type.
///
/// Wire format — a single JSON object:
/// ```
/// { "state": "connected", "message": null }
/// { "state": "failed",    "message": "SPICE serial port read failed — errno 32 (Broken pipe)." }
/// ```
public enum SpiceClipboardState: String, Codable, Sendable {
    /// The clipboard bridge hasn't started yet. Host shows
    /// a gray pill ("Clipboard Off" / "Starting up…").
    ///
    /// The explicit raw value below is required by the
    /// `raw_value_for_camel_cased_codable_enum` opt-in lint rule
    /// (this case name is camelCase) but intentionally matches
    /// Swift's default synthesis — that's the wire value the
    /// guest and host already agree on (see
    /// `SpiceStatusSnapshotTests`). That puts it in direct
    /// conflict with the default `redundant_string_enum_value`
    /// rule, which flags a raw value equal to its case name;
    /// silencing that one rule on this one line documents the
    /// wire format without breaking the existing contract.
    // swiftlint:disable:next redundant_string_enum_value
    case notStarted = "notStarted"

    /// Serial port opened, waiting for the SPICE
    /// capabilities handshake. Host shows an amber pill
    /// ("Connecting…").
    case connecting

    /// Handshake complete, clipboard sync is live. Host
    /// shows a green pill ("Clipboard Shared").
    case connected

    /// The bridge encountered an unrecoverable error. Host
    /// shows a red pill with the accompanying `message`
    /// surfaced in a tooltip.
    case failed
}

/// Payload returned by `GET /api/v1/spice/status`.
public struct SpiceStatusSnapshot: Codable, Sendable, Equatable {
    /// Coarse-grained state the host maps to a pill color.
    public var state: SpiceClipboardState

    /// Optional human-readable detail — used only for
    /// `.failed` today to carry the underlying error's
    /// `LocalizedError.errorDescription`. Nil for healthy
    /// states so the JSON stays tight.
    public var message: String?

    public init(state: SpiceClipboardState, message: String? = nil) {
        self.state = state
        self.message = message
    }
}
