import Foundation

/// Identifier for which clipboard a message refers to.
///
/// macOS has only one system pasteboard, so our agent always
/// uses ``clipboard`` — but the selection byte is still
/// present on the wire when ``VDAgentCapability/clipboardSelection``
/// is negotiated, and peers may distinguish between multiple
/// X11-style selections we need to parse.
public enum VDAgentClipboardSelection: UInt8, Sendable {
    /// The primary system clipboard (macOS `NSPasteboard.general`,
    /// X11 `CLIPBOARD`, Wayland equivalents). All our sends
    /// use this.
    case clipboard = 0

    /// The X11 "PRIMARY" selection (middle-click paste). No
    /// macOS equivalent — we ignore incoming messages tagged
    /// with this.
    case primary = 1

    /// The rarely-used X11 "SECONDARY" selection. Also ignored
    /// on macOS.
    case secondary = 2
}

/// The MIME-ish type of clipboard payload, from
/// `VD_AGENT_CLIPBOARD_*` in `spice/vd_agent.h`.
///
/// A single grab message advertises a *list* of these types —
/// the peer picks one when requesting data. Our agent maps
/// each to one or more `NSPasteboard.PasteboardType` values in
/// a higher-level module.
public enum VDAgentClipboardType: UInt32, Sendable {
    /// Zero-value used in grab bitmaps to indicate "no more
    /// types after this one". Never used as an actual
    /// payload type.
    case none = 0

    /// Plain UTF-8 text. Line endings follow whatever the
    /// `GUEST_LINEEND_*` capability negotiated. No BOM.
    case utf8Text = 1

    /// PNG image. Full file with header — not raw pixel data.
    case imagePNG = 2

    /// Windows bitmap (BMP). Largest of the image types on
    /// the wire; supported for cross-platform paste.
    case imageBMP = 3

    /// TIFF image. Apple's Preview and Screenshot tools emit
    /// TIFF on the host pasteboard by default when you copy a
    /// screenshot area.
    case imageTIFF = 4

    /// JPEG image. Lossy but small.
    case imageJPG = 5
}
