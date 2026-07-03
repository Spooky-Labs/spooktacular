import Foundation

/// Builds and parses the `VD_AGENT_ANNOUNCE_CAPABILITIES`
/// message payload.
///
/// Wire layout:
///
/// ```
/// offset  size  field
/// 0       4     request  (UInt32)  — 1 to ask the peer to
///                                    reply with their own
///                                    announcement, 0 if
///                                    we're replying
/// 4       4*N   caps     (UInt32×) — N capability words;
///                                    bit b in word w means
///                                    capability (w*32+b)
/// ```
///
/// The number of words `N` is implicit from the payload
/// length: `(payloadSize - 4) / 4`. Our agent only needs one
/// word (highest cap bit is 14), but we parse multi-word
/// payloads from peers gracefully.
public struct VDAgentAnnounceCapabilities: Equatable, Sendable {

    /// When `true`, the peer must reply with its own
    /// announcement. The host sends `request = true` on
    /// first connection; the guest responds with
    /// `request = false`.
    public var request: Bool

    /// The announced capability set.
    public var capabilities: VDAgentCapabilities

    public init(request: Bool, capabilities: VDAgentCapabilities) {
        self.request = request
        self.capabilities = capabilities
    }

    /// Serializes to the payload bytes. Emits a single
    /// 32-bit capability word, which covers every bit our
    /// enum defines.
    public func encode() -> Data {
        var data = Data(capacity: 8)
        data.appendLE(UInt32(request ? 1 : 0))
        data.appendLE(capabilities.rawValue)
        return data
    }

    /// Parses an announce-capabilities payload. Any capability
    /// words beyond the first are OR-folded into the result:
    /// we don't model bits > 31 yet, but we must not crash if
    /// a forward-compatible peer sends more of them.
    public static func decode(payload: Data) throws -> Self {
        guard payload.count >= 8 else {
            throw SpiceCodec.DecodeError.truncated(
                expected: 8, got: payload.count
            )
        }
        let requestFlag = payload.readLE(UInt32.self, at: 0)
        // First capability word is bits 0..31 — the ones we
        // actually model. Ignore bits 32+ silently.
        let capsWord = payload.readLE(UInt32.self, at: 4)
        return Self(
            request: requestFlag != 0,
            capabilities: VDAgentCapabilities(rawValue: capsWord)
        )
    }
}
