import Foundation
#if canImport(AppKit)
import AppKit
#endif
import SpiceProtocol

/// Abstraction over `NSPasteboard` so the state-machine actor
/// can be unit-tested without touching the real system
/// clipboard.
///
/// The real implementation (``AppKitPasteboardBridge``) wraps
/// `NSPasteboard.general`; tests inject a plain-Swift double.
/// Protocol is `Sendable` since the agent actor hops its
/// reads/writes across isolation boundaries.
///
/// ## Text only, by design
///
/// We deliberately support `utf8Text` and nothing else.
/// Images over Apple's `VZSpiceAgentPortAttachment` are not
/// reliable — the peer accepts multi-megabyte image payloads
/// on the wire but silently drops them before writing to the
/// host `NSPasteboard`, and the failure mode spreads to
/// subsequent clipboard operations. See the 2026-04-22 trace
/// for details. Users needing image transfer should use a
/// shared folder, `scp`, or AirDrop.
public protocol PasteboardBridge: Sendable {
    /// Monotonic counter that increments whenever the system
    /// clipboard contents change — including changes written
    /// by this process. `NSPasteboard.changeCount` is the
    /// canonical source; Apple documents polling as the only
    /// supported way to observe pasteboard changes (there's
    /// no KVO or notification).
    func currentChangeCount() async -> Int

    /// The SPICE clipboard types currently on the pasteboard,
    /// in preference order (best format first). Returns an
    /// empty array if the pasteboard has nothing we know how
    /// to represent — in the text-only bridge, that's any
    /// pasteboard that doesn't declare `public.utf8-plain-text`.
    func availableTypes() async -> [VDAgentClipboardType]

    /// Reads the pasteboard content for the given SPICE type.
    /// Returns `nil` if no content is available in that
    /// representation — which can happen if another app
    /// replaced the pasteboard between `availableTypes` and
    /// `read`.
    func read(type: VDAgentClipboardType) async -> Data?

    /// Writes `data` to the pasteboard as the given SPICE
    /// type, replacing all prior contents. Returns the new
    /// `changeCount` so the caller can ignore its own echo
    /// in the next poll iteration.
    func write(type: VDAgentClipboardType, data: Data) async -> Int

    /// Diagnostic: the raw UTI strings the pasteboard currently
    /// declares — everything, not just what we map to SPICE
    /// types. Used by the agent to log when a user's copy
    /// surprises us (e.g. an image source that declares HEIC
    /// only, or a file-reference copy instead of image bytes).
    func declaredPasteboardTypes() async -> [String]
}

// MARK: - Type mapping

/// Mapping between SPICE's clipboard-type enum and AppKit's
/// `NSPasteboard.PasteboardType`.
///
/// Text-only by design. The enum cases for image types still
/// exist in ``VDAgentClipboardType`` (they're part of the
/// wire protocol we decode from peers), but this bridge
/// refuses to advertise, read, or write them.
public enum SpiceClipboardTypeMapping {

    #if canImport(AppKit)

    /// The single SPICE↔AppKit type mapping we support.
    /// Kept as a member (rather than inlined) so tests and
    /// diagnostic code can reference it by name.
    static let textEntry: (spice: VDAgentClipboardType, appKit: NSPasteboard.PasteboardType) =
        (.utf8Text, .string)

    /// Maps a SPICE clipboard type to the matching
    /// `NSPasteboard.PasteboardType`, or `nil` if we don't
    /// carry that format. In the text-only bridge, only
    /// `.utf8Text` ever resolves.
    public static func pasteboardType(
        for spice: VDAgentClipboardType
    ) -> NSPasteboard.PasteboardType? {
        spice == textEntry.spice ? textEntry.appKit : nil
    }

    /// Inspects a pasteboard and returns the SPICE types it
    /// can represent. Text-only: we return `[.utf8Text]` if
    /// the pasteboard declares `public.utf8-plain-text`, and
    /// `[]` otherwise.
    ///
    /// We deliberately don't synthesise text from richer
    /// formats (RTF, HTML) because doing so would silently
    /// strip formatting the user explicitly copied.
    public static func availableSpiceTypes(
        in pasteboard: NSPasteboard
    ) -> [VDAgentClipboardType] {
        let declared = Set(pasteboard.types ?? [])
        return declared.contains(textEntry.appKit) ? [textEntry.spice] : []
    }

    #endif
}

// MARK: - AppKit implementation

#if canImport(AppKit)
/// Production implementation backed by `NSPasteboard.general`.
///
/// An actor so `read` + `write` can't interleave mid-operation
/// (NSPasteboard is thread-safe for independent reads but the
/// `clearContents` + `setString` pair is a read-modify-write).
public actor AppKitPasteboardBridge: PasteboardBridge {

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public func currentChangeCount() -> Int {
        pasteboard.changeCount
    }

    public func availableTypes() -> [VDAgentClipboardType] {
        SpiceClipboardTypeMapping.availableSpiceTypes(in: pasteboard)
    }

    public func declaredPasteboardTypes() -> [String] {
        (pasteboard.types ?? []).map(\.rawValue)
    }

    public func read(type: VDAgentClipboardType) -> Data? {
        // Text-only. Anything else returns nil; the agent's
        // `handleGrab` filters incoming GRABs to text so this
        // path isn't hit for image types in practice, but be
        // defensive.
        guard type == .utf8Text,
              let pbType = SpiceClipboardTypeMapping.pasteboardType(for: type),
              let rawData = pasteboard.data(forType: pbType)
        else {
            return nil
        }
        // Validate UTF-8 before forwarding. Non-UTF-8 bytes
        // sitting under `.string` (malformed source app, or a
        // compromised guest app) could include terminal
        // escape sequences or other content that surprises
        // text-handling apps on the host.
        guard String(data: rawData, encoding: .utf8) != nil else {
            return nil
        }
        return rawData
    }

    public func write(type: VDAgentClipboardType, data: Data) -> Int {
        // Only honour text. Silently ignore other types — the
        // agent filters incoming GRABs so this is just a belt-
        // and-braces guard for any wire-level oddity.
        guard type == .utf8Text else {
            return pasteboard.changeCount
        }
        pasteboard.clearContents()
        // `NSPasteboard.setString(_:forType:)` does the right
        // thing for a byte sequence the peer labelled as UTF-8;
        // if the bytes aren't valid UTF-8 the conversion fails
        // and we leave the pasteboard empty (post-clearContents)
        // rather than writing garbage labelled as a string.
        if let string = String(data: data, encoding: .utf8) {
            pasteboard.setString(string, forType: .string)
        }
        return pasteboard.changeCount
    }
}
#endif
