import Foundation

/// `SPICE_LINK_ERR_*` — every link-stage error code defined in
/// the SPICE protocol specification.
///
/// The SPICE link handshake is the initial exchange between a
/// SPICE client and SPICE server before any channel messages
/// flow. Apple's `VZSpiceAgentPortAttachment` performs this
/// handshake host-side on our behalf, so guest-side agents
/// built on top of this package will never observe these codes
/// directly on the wire — but consumers that extend this
/// package to speak the full SPICE protocol (display, inputs,
/// playback, record) need the typed vocabulary.
///
/// These same values also appear in:
///
/// - ``SpiceLinkReply.error`` on every failed handshake.
/// - `SPICE_MSG_DISCONNECTING.reason` when either side reports
///   orderly disconnection.
/// - `SPICE_MSG_NOTIFY.what` when `severity` is
///   ``SpiceNotifySeverity/error``.
///
/// Source: [SPICE Agent Protocol spec](https://www.spice-space.org/spice-protocol.html).
public enum SpiceLinkError: UInt32, Error, Sendable, CaseIterable {
    /// No error. The handshake completed successfully. Present
    /// in the enum for round-tripping; not thrown as an error.
    case ok = 0

    /// Generic unspecified error. The server encountered a
    /// fault it couldn't attribute to a more specific cause.
    case error = 1

    /// The client sent a `SpiceLinkMess` whose `magic` field
    /// did not equal `SPICE_MAGIC` (ASCII "REDQ"). Usually
    /// means the transport is mis-framed or the peer isn't a
    /// SPICE server at all.
    case invalidMagic = 2

    /// A well-formed message carried field values the server
    /// rejected (out-of-range sizes, malformed capability
    /// vectors, impossible channel IDs, etc.).
    case invalidData = 3

    /// Client and server disagreed on protocol major version
    /// in an incompatible way. Same major version is required;
    /// minor-version differences are compatible.
    case versionMismatch = 4

    /// The server refused to continue on an unsecured
    /// (plain-TCP) channel and demands TLS. The client must
    /// reconnect over the secure port.
    case needSecured = 5

    /// The inverse — the server refused the secure channel and
    /// wants a plain connection. Rare; typically a deployment
    /// misconfiguration.
    case needUnsecured = 6

    /// Ticket mismatch. The client's encrypted password did
    /// not match the server's stored ticket, or the ticket
    /// expired mid-handshake.
    case permissionDenied = 7

    /// For non-main channels, `SpiceLinkMess.connection_id`
    /// referenced a session ID the server doesn't recognize.
    /// Usually means the client's main-channel connection
    /// dropped and its derived channels must reconnect too.
    case badConnectionID = 8

    /// The client requested a channel type (display, inputs,
    /// record, etc.) the server didn't advertise in its
    /// channel list.
    case channelNotAvailable = 9
}

extension SpiceLinkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .ok:
            return "SPICE link handshake succeeded (SPICE_LINK_ERR_OK)."
        case .error:
            return "SPICE link handshake failed with a generic server error (SPICE_LINK_ERR_ERROR)."
        case .invalidMagic:
            return "SPICE link message magic number was not 'REDQ' — peer may not be a SPICE endpoint (SPICE_LINK_ERR_INVALID_MAGIC)."
        case .invalidData:
            return "SPICE link message contained malformed field values (SPICE_LINK_ERR_INVALID_DATA)."
        case .versionMismatch:
            return "SPICE protocol major-version mismatch between client and server (SPICE_LINK_ERR_VERSION_MISMATCH)."
        case .needSecured:
            return "SPICE server requires a TLS-secured connection; reconnect via the secure port (SPICE_LINK_ERR_NEED_SECURED)."
        case .needUnsecured:
            return "SPICE server refuses TLS on this port; reconnect without encryption (SPICE_LINK_ERR_NEED_UNSECURED)."
        case .permissionDenied:
            return "SPICE server rejected the ticket — bad password or expired credentials (SPICE_LINK_ERR_PERMISSION_DENIED)."
        case .badConnectionID:
            return "SPICE server does not recognize this connection ID; main channel likely disconnected (SPICE_LINK_ERR_BAD_CONNECTION_ID)."
        case .channelNotAvailable:
            return "SPICE server did not advertise the requested channel type (SPICE_LINK_ERR_CHANNEL_NOT_AVAILABLE)."
        }
    }
}

/// `SPICE_WARN_*` — warning severity codes in
/// `SPICE_MSG_NOTIFY`. Currently the spec defines only the
/// generic case; additional values will extend this enum.
public enum SpiceNotifyWarning: UInt32, Sendable, CaseIterable {
    /// `SPICE_WARN_GENERAL` — unspecified server warning. The
    /// accompanying notify message string carries the detail.
    case general = 0
}

/// `SPICE_INFO_*` — informational severity codes in
/// `SPICE_MSG_NOTIFY`. Currently the spec defines only the
/// generic case.
public enum SpiceNotifyInfo: UInt32, Sendable, CaseIterable {
    /// `SPICE_INFO_GENERAL` — unspecified server informational
    /// message. The accompanying notify message string carries
    /// the detail.
    case general = 0
}

/// `SPICE_NOTIFY_SEVERITY_*` — the severity field of
/// `SPICE_MSG_NOTIFY`. Determines which of
/// ``SpiceLinkError`` / ``SpiceNotifyWarning`` /
/// ``SpiceNotifyInfo`` the `what` field should be interpreted
/// as.
public enum SpiceNotifySeverity: UInt32, Sendable, CaseIterable {
    case info = 0
    case warning = 1
    case error = 2
}
