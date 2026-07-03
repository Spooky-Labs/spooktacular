import Foundation

/// Individual `VD_AGENT_CAP_*` capability bits.
///
/// Each peer announces its capability set at connection start,
/// and the effective feature set is the **intersection**. If
/// one side supports a capability and the other doesn't, that
/// feature is off.
///
/// Bit numbers come from `spice/vd_agent.h` in the public
/// spice-protocol repository. The names (and some semantics)
/// follow the SPICE tradition of growing the enum over years —
/// older clipboard features were supplanted by newer, more
/// capable ones. Our Mac-guest agent announces a carefully
/// chosen subset (see ``Capabilities/macGuestDefault``).
public enum VDAgentCapability: UInt32, Sendable {

    /// Pointer-state streaming. QEMU/SPICE uses this for tablet
    /// input; Apple's VZ framework has its own input path so
    /// a Mac guest agent deliberately omits this bit.
    case mouseState = 0

    /// Monitors-config streaming. Same story: Apple handles
    /// display via `VZMacGraphicsDevice` — we don't send this.
    case monitorsConfig = 1

    /// The peer will reply with ACK to messages that request
    /// acknowledgement. Useful for the grab→request→data
    /// round-trip since we often care whether the host
    /// received a grab.
    case reply = 2

    /// **Legacy** push-model clipboard. When present, clipboard
    /// content is sent immediately on every copy. Modern
    /// agents use ``clipboardByDemand`` instead, which is
    /// strictly better (no bandwidth wasted on unread copies).
    case clipboard = 3

    /// Display configuration streaming. Not relevant on macOS.
    case displayConfig = 4

    /// **Pull-model** clipboard. The sender emits `GRAB` when
    /// new data is available; the receiver emits `REQUEST`
    /// only when it actually wants to paste, and the sender
    /// responds with the payload. Every modern SPICE agent
    /// uses this mode.
    case clipboardByDemand = 5

    /// Clipboard messages carry a 4-byte selection prefix
    /// (1-byte selection ID + 3 bytes reserved) before the
    /// type. Lets agents distinguish between X11-style
    /// CLIPBOARD / PRIMARY / SECONDARY selections. On macOS
    /// only the single system clipboard exists, but we still
    /// announce this cap so the host framework sends
    /// selection-prefixed messages we can parse uniformly.
    case clipboardSelection = 6

    /// Monitors-config messages can carry a sparse bitmap
    /// rather than a dense array. Harmless to announce.
    case sparseMonitorsConfig = 7

    /// Guest line endings are LF, not CRLF. macOS text
    /// pasteboards are LF; setting this prevents the host
    /// from mangling line endings into CRLF on paste.
    case guestLineendLF = 8

    /// Guest line endings are CRLF. Windows guests set this.
    case guestLineendCRLF = 9

    /// Supports `VDAgentMaxClipboard` negotiation — peers
    /// exchange the largest clipboard payload they'll accept
    /// in one message, so senders can chunk or refuse early.
    case maxClipboard = 10

    /// Supports forwarding audio-volume changes between
    /// host and guest. Not used by our agent yet but cheap
    /// to announce.
    case audioVolumeSync = 11

    /// Supports the `GraphicsDeviceInfo` message. Apple's
    /// VZ bridge uses this to discover guest display metrics.
    case graphicsDeviceInfo = 12

    /// When regrabbing the same clipboard selection, the
    /// sender does NOT need to send a preceding RELEASE. A
    /// modern optimization that avoids a pointless
    /// round-trip on rapid copy-copy-copy activity.
    case clipboardNoReleaseOnRegrab = 13

    /// Every grab carries a 64-bit serial number so the two
    /// sides can resolve race conditions (simultaneous grabs)
    /// deterministically by comparing serials.
    case clipboardGrabSerial = 14
}

/// A compact bitmap of ``VDAgentCapability`` flags.
///
/// Wire format, per the SPICE spec: `N` little-endian `UInt32`
/// words where bit `b` corresponds to the capability with
/// numeric value `b`. Word 0 holds bits 0..31, word 1 holds
/// bits 32..63, etc. The spec lets agents send as many words
/// as they need to cover their highest-numbered capability.
///
/// Our implementation's highest bit is
/// ``VDAgentCapability/clipboardGrabSerial`` (14), so one
/// 32-bit word is sufficient. We still support parsing
/// multi-word bitmaps from peers that announce more caps than
/// we recognize — unknown bits are silently ignored, which is
/// the spec-compliant behavior for forward compatibility.
public struct VDAgentCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// Tests whether a specific capability bit is set.
    public func contains(_ capability: VDAgentCapability) -> Bool {
        rawValue & (1 << capability.rawValue) != 0
    }

    /// The set of capabilities announced by a Spooktacular
    /// macOS-guest agent. Chosen to match what a modern SPICE
    /// host expects from a macOS clipboard bridge: no mouse,
    /// no monitors config (VZ handles those natively),
    /// pull-model clipboard with selection prefix and grab
    /// serials.
    ///
    /// ``clipboard`` (bit 3) is the legacy push-model cap;
    /// every deployed SPICE implementation advertises it as a
    /// prerequisite for the modern extensions like
    /// ``clipboardByDemand`` and ``clipboardSelection``.
    /// Empirically, Apple's `VZSpiceAgentPortAttachment`
    /// silently drops `CLIPBOARD_REQUEST`s from peers that
    /// announce `clipboardByDemand` without also announcing
    /// `clipboard` — matching the spice-gtk / spice-vdagent /
    /// Windows `spice-guest-tools` convention.
    public static let macGuestDefault: VDAgentCapabilities = [
        .reply,
        .clipboard,
        .clipboardByDemand,
        .clipboardSelection,
        .sparseMonitorsConfig,
        .guestLineendLF,
        // `.maxClipboard` deliberately omitted: announcing
        // this capability commits us to exchanging a
        // `VDAgentMaxClipboard` message (vd_agent message
        // type 14) after ANNOUNCE, declaring the largest
        // clipboard payload we'll accept. We don't implement
        // that message in either direction, so advertising
        // the cap is spec-incorrect — a strict peer could
        // block REQUEST → CLIPBOARD round-trips waiting for
        // our max-size declaration that never arrives. We'd
        // rather let the peer use its own default limits
        // than stall the handshake on a feature we don't
        // honor.
        .clipboardNoReleaseOnRegrab,
        .clipboardGrabSerial,
    ]
}

extension VDAgentCapabilities: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: VDAgentCapability...) {
        rawValue = elements.reduce(0) { $0 | (1 << $1.rawValue) }
    }
}
