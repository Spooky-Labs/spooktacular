import Foundation

/// Length-prefixed `Codable` framing for the host ↔ guest event
/// channel.
///
/// Each frame on the wire is:
///
/// ```
/// ┌──────────────────────┬────────────────────────────┐
/// │  4-byte big-endian   │  N bytes of JSONEncoder    │
/// │  unsigned length N   │  output (UTF-8 `GuestEvent`│
/// │                      │  encoded body)             │
/// └──────────────────────┴────────────────────────────┘
/// ```
///
/// Why length-prefix + JSON, not HTTP/NDJSON:
///
/// - **Apple-native Codable.** `JSONEncoder` + `JSONDecoder` are
///   Swift Foundation's canonical serialization pair; they work
///   identically on macOS and on Linux's swift-corelibs
///   Foundation, so host and guest agree on the wire bytes for
///   free.
/// - **No protocol ceremony.** Each frame is exactly the bytes
///   of the encoded value. No `Transfer-Encoding: chunked`, no
///   headers, no request line. Fewer bytes per tick, fewer
///   parser edge cases, and the stream has no ambiguous "end
///   of headers" boundary.
/// - **Framing is unambiguous.** A fixed-width prefix tells the
///   reader exactly how many bytes to consume; the decoder
///   never has to hunt for delimiters inside payloads, unlike
///   newline-delimited formats that need escaping for embedded
///   newlines.
///
/// 4-byte length caps individual frames at 4 GiB — more than
/// three orders of magnitude above the largest frame this
/// channel ever carries (a ports snapshot with thousands of
/// entries sits in the low tens of KB).
public enum AgentFrameCodec {

    /// Raised when the decoder observes an invalid frame.
    public enum DecodeError: Error, Sendable, Equatable {
        /// The peer closed before a complete frame arrived.
        case unexpectedEOF
        /// The declared length exceeds ``maxFrameBytes``.
        case frameTooLarge(declared: UInt32, limit: UInt32)
    }

    /// Hard cap on a single frame's body length. 16 MiB is
    /// comfortably above any legitimate event payload (a
    /// `GuestEvent.ports` snapshot with 10k entries is under
    /// 1 MB) and far below `UInt32.max` so a malformed /
    /// hostile length header aborts the stream instead of
    /// triggering a giant allocation.
    public static let maxFrameBytes: UInt32 = 16 * 1024 * 1024

    /// Encodes a `Codable` value into one framed message.
    ///
    /// Writes the 4-byte length prefix followed by the encoded
    /// bytes. Callers pass the returned `Data` to `write(2)` as
    /// a single atomic buffer — on a stream socket the kernel
    /// will partial-write if the buffer exceeds `SO_SNDBUF`,
    /// which is fine: the consumer reconstructs the frame from
    /// whatever byte stream arrives.
    public static func encode<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let body = try encoder.encode(value)
        precondition(
            body.count <= Int(maxFrameBytes),
            "frame body exceeds \(maxFrameBytes) byte limit"
        )
        var frame = Data(capacity: 4 + body.count)
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(body)
        return frame
    }

    /// Reads one frame from `source` and decodes it.
    ///
    /// `source` is called repeatedly with a desired byte count
    /// and must return exactly that many bytes. An empty return
    /// signals EOF, which surfaces as ``DecodeError/unexpectedEOF``.
    ///
    /// The separation between "read N bytes" (caller's
    /// responsibility) and "parse frame" (this function)
    /// keeps the codec transport-agnostic: the host side
    /// reads from a `VZVirtioSocketConnection` `FileHandle`,
    /// the Linux guest reads from a raw Glibc `read(2)`, and
    /// both plug into the same decode call.
    public static func decode<T: Decodable>(
        _ type: T.Type,
        from source: (Int) throws -> Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> T {
        let header = try source(4)
        guard header.count == 4 else {
            throw DecodeError.unexpectedEOF
        }
        let length = header.withUnsafeBytes { raw -> UInt32 in
            let be = raw.load(as: UInt32.self)
            return UInt32(bigEndian: be)
        }
        guard length <= maxFrameBytes else {
            throw DecodeError.frameTooLarge(declared: length, limit: maxFrameBytes)
        }
        let body = try source(Int(length))
        guard body.count == Int(length) else {
            throw DecodeError.unexpectedEOF
        }
        return try decoder.decode(type, from: body)
    }
}
