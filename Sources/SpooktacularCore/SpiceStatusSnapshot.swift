import Foundation

/// Current state of the guest's SPICE clipboard bridge —
/// returned by `GET /api/v1/spice/status`, decoded by the
/// host's workspace toolbar to pick a tri-state pill color.
///
/// Lives in ``SpooktacularCore`` (not
/// ``SpooktacularGuestAgentCore``) because BOTH sides of the
/// wire need to encode/decode it: the guest-tools app
/// produces the payload, the host's `GuestAgentClient`
/// consumes it. Keeping the DTO in Core avoids forcing the
/// host to import the guest-side library just to name the
/// type.
///
/// Wire format — a single JSON object:
/// ```
/// { "state": "connected", "message": null }
/// { "state": "failed",    "message": "SPICE serial port read failed — errno 32 (Broken pipe)." }
/// ```
public enum SpiceClipboardState: String, Codable, Sendable {
    /// The clipboard bridge hasn't started yet. Host shows
    /// a gray pill ("Clipboard Off" / "Starting up…").
    case notStarted

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
