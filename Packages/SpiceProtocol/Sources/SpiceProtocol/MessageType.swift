import Foundation

/// Numeric IDs for SPICE `vd_agent` message types.
///
/// Only the subset needed for clipboard sharing is enumerated
/// here. Additional types (mouse state, monitors config, audio
/// volume) exist in the broader SPICE spec but aren't needed on
/// Apple's Virtualization framework — VZ's bridge handles
/// input and display natively.
///
/// Source: `spice/vd_agent.h` in spice-protocol, cross-checked
/// against the spice-space.org agent protocol specification.
public enum VDAgentMessageType: UInt32, Sendable {
    // MARK: - Clipboard

    /// Actual clipboard payload (the bytes of the text, image,
    /// etc.). Sent in response to a ``clipboardRequest``.
    case clipboard = 4

    /// Announces which `VD_AGENT_CAP_*` bits this endpoint
    /// supports. Both sides send one at connection start; the
    /// intersection is the effective feature set.
    case announceCapabilities = 6

    /// "I have new clipboard data of these types available."
    /// The sender does *not* include data here — the peer
    /// asks for it later with ``clipboardRequest`` only if it
    /// wants to paste. This is the pull-model that
    /// `VD_AGENT_CAP_CLIPBOARD_BY_DEMAND` enables.
    case clipboardGrab = 7

    /// "Please send me the clipboard data of type X." The peer
    /// responds with a ``clipboard`` message.
    case clipboardRequest = 8

    /// "My clipboard is no longer available — drop any cached
    /// grab offer." Sent when the sender's pasteboard is
    /// cleared or another app takes over.
    case clipboardRelease = 9
}
