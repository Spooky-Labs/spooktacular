import Foundation

/// Encode / decode primitives for the SPICE vd_agent wire
/// format.
///
/// All integers on the wire are **little-endian, packed, no
/// padding**. Swift's `withUnsafeBytes` and raw-pointer bulk
/// copies preserve the memory layout we want as long as we
/// write each field individually (not via struct-copy, because
/// Swift makes no guarantees about field alignment inside a
/// user-defined struct).
///
/// These helpers live in a dedicated file so the
/// encoding/decoding logic can be exhaustively unit-tested
/// against the spec without dragging in the rest of the
/// package.
public enum SpiceCodec {

    // MARK: - Errors

    public enum DecodeError: Error, Equatable, Sendable, LocalizedError {
        /// A buffer ran out before the expected number of
        /// bytes were consumed. `expected` is the minimum
        /// length the decoder needed; `got` is what it had.
        case truncated(expected: Int, got: Int)

        /// A field's value was outside the range that any
        /// implementation recognizes. Enum-valued fields
        /// (message type, capability, clipboard type) map to
        /// this when a peer sends a value we don't know.
        case unknownValue(field: String, raw: UInt64)

        /// Protocol version mismatch — the sender claimed a
        /// protocol number we don't speak. The SPICE spec
        /// has only ever defined version 1.
        case unsupportedProtocol(got: UInt32)

        public var errorDescription: String? {
            switch self {
            case .truncated(let expected, let got):
                return "Truncated SPICE frame: expected at least \(expected) bytes, got \(got)."
            case .unknownValue(let field, let raw):
                return "Unknown SPICE \(field) value \(raw) on the wire."
            case .unsupportedProtocol(let got):
                return "Unsupported SPICE protocol version \(got); this package speaks version \(VDAgentMessage.currentProtocolVersion)."
            }
        }
    }

    // MARK: - Chunk header

    /// Encodes a ``VDIChunkHeader`` into 8 little-endian bytes.
    public static func encode(chunk: VDIChunkHeader) -> Data {
        var data = Data(capacity: VDIChunkHeader.byteCount)
        data.appendLE(chunk.port)
        data.appendLE(chunk.size)
        return data
    }

    /// Parses an 8-byte chunk header from the front of `data`.
    /// Does not consume bytes — caller slices.
    public static func decodeChunkHeader(_ data: Data) throws -> VDIChunkHeader {
        guard data.count >= VDIChunkHeader.byteCount else {
            throw DecodeError.truncated(
                expected: VDIChunkHeader.byteCount, got: data.count
            )
        }
        let port = data.readLE(UInt32.self, at: 0)
        let size = data.readLE(UInt32.self, at: 4)
        return VDIChunkHeader(port: port, size: size)
    }

    // MARK: - Agent header

    /// Encodes a ``VDAgentMessage`` into 20 little-endian
    /// bytes. Does not include the payload — caller appends.
    public static func encode(message: VDAgentMessage) -> Data {
        var data = Data(capacity: VDAgentMessage.byteCount)
        data.appendLE(message.protocolVersion)
        data.appendLE(message.type)
        data.appendLE(message.opaque)
        data.appendLE(message.size)
        return data
    }

    /// Parses a 20-byte agent message header.
    public static func decodeAgentHeader(_ data: Data) throws -> VDAgentMessage {
        guard data.count >= VDAgentMessage.byteCount else {
            throw DecodeError.truncated(
                expected: VDAgentMessage.byteCount, got: data.count
            )
        }
        let proto = data.readLE(UInt32.self, at: 0)
        guard proto == VDAgentMessage.currentProtocolVersion else {
            throw DecodeError.unsupportedProtocol(got: proto)
        }
        let type = data.readLE(UInt32.self, at: 4)
        let opaque = data.readLE(UInt64.self, at: 8)
        let size = data.readLE(UInt32.self, at: 16)
        return VDAgentMessage(
            protocolVersion: proto,
            type: type,
            opaque: opaque,
            size: size
        )
    }

    // MARK: - Full frames

    /// SPICE's maximum per-chunk body size — the `VDIChunkHeader.size`
    /// ceiling, matching `VD_AGENT_MAX_DATA_SIZE` in the authoritative
    /// `spice/vd_agent.h`:
    ///
    /// ```c
    /// #define VD_AGENT_MAX_DATA_SIZE 2048
    /// ```
    ///
    /// Any `VDAgentMessage` whose header + payload exceeds
    /// this must be fragmented across multiple chunks. This
    /// was the cause of the screenshot-clipboard regression:
    /// a 1–5 MB image payload was being emitted as a single
    /// chunk whose `chunk.size` field wrapped fine but whose
    /// receiver (VZ's host-side SPICE bridge) enforces the
    /// 2 KB ceiling and dropped the frame.
    public static let maxChunkBodySize: Int = 2048

    /// Builds the on-wire bytes for a typed agent message,
    /// fragmented across one or more chunks per the SPICE
    /// protocol.
    ///
    /// ## Wire layout
    ///
    /// When the agent header (20 bytes) + payload fits within
    /// ``maxChunkBodySize``, a single chunk is emitted:
    ///
    /// ```
    /// [VDIChunkHeader (8) | VDAgentMessage (20) | payload]
    /// ```
    ///
    /// Otherwise the message is fragmented:
    ///
    /// ```
    /// First chunk:    [chunkHdr (8) | agentHdr (20) | payload[0 ..< 2028]]
    /// Continuation:   [chunkHdr (8) | payload[2028 ..< 4076]]
    /// …                ...
    /// Final chunk:    [chunkHdr (8) | payload[N-rem ..< N]]
    /// ```
    ///
    /// The VDAgentMessage header appears ONLY in the first
    /// chunk; continuation chunks carry raw payload bytes.
    /// The receiver uses `VDAgentMessage.size` (set in the
    /// first chunk's agent header) to know the total payload
    /// length and therefore when reassembly completes.
    ///
    /// The tty is a byte stream with no packet boundaries, so
    /// concatenating every chunk into a single `Data` is
    /// semantically identical to writing them separately —
    /// the peer's framer splits on the `VDIChunkHeader.size`
    /// field.
    public static func frame(
        type: VDAgentMessageType,
        payload: Data
    ) -> Data {
        let agentHeader = VDAgentMessage(
            type: type,
            size: UInt32(payload.count)
        )
        let agentHeaderData = encode(message: agentHeader)

        var output = Data(
            capacity: VDIChunkHeader.byteCount
                + VDAgentMessage.byteCount
                + payload.count
        )

        // First chunk carries the agent header + as much
        // payload as fits within the 2 KB body cap.
        let firstChunkPayloadCapacity = maxChunkBodySize - VDAgentMessage.byteCount
        let firstChunkPayloadBytes = Swift.min(
            firstChunkPayloadCapacity,
            payload.count
        )
        let firstChunkBodySize = VDAgentMessage.byteCount + firstChunkPayloadBytes
        output.append(encode(chunk: VDIChunkHeader(size: UInt32(firstChunkBodySize))))
        output.append(agentHeaderData)
        output.append(payload.prefix(firstChunkPayloadBytes))

        // Continuation chunks: ≤ 2 KB payload each, no header
        // reinterpretation.
        var offset = firstChunkPayloadBytes
        while offset < payload.count {
            let remaining = payload.count - offset
            let take = Swift.min(maxChunkBodySize, remaining)
            output.append(encode(chunk: VDIChunkHeader(size: UInt32(take))))
            output.append(payload[payload.startIndex.advanced(by: offset)..<payload.startIndex.advanced(by: offset + take)])
            offset += take
        }

        return output
    }
}

// MARK: - Data helpers (internal — used by message encoders/decoders)

extension Data {
    /// Appends a fixed-width integer in little-endian order.
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    /// Reads a fixed-width little-endian integer at a byte
    /// offset. Callers must have already bounds-checked.
    func readLE<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
        precondition(offset + MemoryLayout<T>.size <= count)
        let raw = withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: raw)
    }
}
