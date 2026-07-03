import Foundation
import SpiceProtocol

/// A fully-decoded SPICE `vd_agent` message delivered to the
/// transport's caller.
///
/// The caller usually only cares about ``type`` and
/// ``payload``; the outer ``chunk`` header is kept around for
/// diagnostics — e.g., to sanity-check `chunk.port` on
/// incoming data. SPICE on Apple's VZ bridge always sets
/// port = 1 (client), so deviations indicate a misconfigured
/// host or a protocol bug worth logging. On multi-chunk
/// messages the `chunk` value is the *first* chunk's header;
/// the rest are reassembled and consumed invisibly.
public struct SpiceIncomingMessage: Sendable {
    public let chunk: VDIChunkHeader
    public let agent: VDAgentMessage
    public let payload: Data

    /// Strongly-typed message kind, or `nil` for values we
    /// don't model. Unknown types aren't an error — peers
    /// may send capabilities-gated messages we simply ignore.
    public var type: VDAgentMessageType? {
        VDAgentMessageType(rawValue: agent.type)
    }

    public init(
        chunk: VDIChunkHeader,
        agent: VDAgentMessage,
        payload: Data
    ) {
        self.chunk = chunk
        self.agent = agent
        self.payload = payload
    }
}

/// Accumulates raw bytes from a virtio-serial port and emits
/// fully-framed SPICE messages.
///
/// Reads on a virtio-serial fd are **not** aligned to message
/// boundaries — a single 8 KB read can deliver anything from
/// half a header to three whole frames plus the start of a
/// fourth. The framer buffers incoming bytes in a single
/// contiguous `Data`, and every time it has enough to decode
/// another `(chunk header + chunk body)*` sequence that
/// completes a logical `VDAgentMessage`, yields one
/// ``SpiceIncomingMessage``.
///
/// ## Multi-chunk reassembly
///
/// SPICE caps each chunk body at
/// ``SpiceProtocol/SpiceCodec/maxChunkBodySize`` (2048 bytes,
/// matching `VD_AGENT_MAX_DATA_SIZE` in the authoritative
/// `spice/vd_agent.h`). Any `VDAgentMessage` whose header +
/// payload exceeds that ceiling is fragmented across multiple
/// chunks:
///
/// - **First chunk** contains a full `VDAgentMessage` header
///   (20 bytes) announcing the total payload size, plus the
///   initial slice of the payload.
/// - **Continuation chunks** carry raw payload bytes only —
///   no repeated header.
///
/// The framer tracks `pending` state between `ingest` calls so
/// payload bytes accumulate until they match
/// `VDAgentMessage.size`, then emits a single
/// ``SpiceIncomingMessage`` with the reassembled payload.
///
/// This matters most for the clipboard bridge: plain-text
/// payloads fit in one chunk, but screenshots (1–5 MB TIFFs)
/// span dozens or hundreds of chunks. The pre-reassembly
/// framer treated every chunk as a self-contained message and
/// threw `truncated` as soon as `agent.size` exceeded
/// `chunk.size`, which tore down the whole transport.
///
/// Not an `actor` because it's always driven from the single
/// read-source handler queue in ``SpiceTransport``. Documented
/// that contract; callers who'd want to share a framer across
/// multiple producers should wrap in their own synchronization.
struct SpiceFramer {

    private var buffer = Data()

    /// In-flight multi-chunk message. `nil` between messages.
    private var pending: PendingMessage?

    private struct PendingMessage {
        /// The FIRST chunk's header — retained for diagnostics
        /// (so the emitted ``SpiceIncomingMessage.chunk`` carries
        /// the original port / first-chunk size).
        let firstChunk: VDIChunkHeader
        let agent: VDAgentMessage
        var payload: Data
    }

    /// Appends freshly-read bytes and returns every complete
    /// message the buffer now contains. Partial frames — or
    /// multi-chunk messages mid-accumulation — are preserved
    /// for the next call.
    mutating func ingest(_ chunk: Data) throws -> [SpiceIncomingMessage] {
        buffer.append(chunk)
        var out: [SpiceIncomingMessage] = []
        while let msg = try drainOne() {
            out.append(msg)
        }
        return out
    }

    /// Tries to pull at least one complete message off the
    /// front of the buffer, consuming as many continuation
    /// chunks as needed to finish the in-progress message.
    ///
    /// Returns `nil` when the buffer is too short to make
    /// forward progress (no chunk header, or an incomplete
    /// chunk body). Throws on genuinely malformed frames
    /// (unsupported protocol version, a first chunk whose body
    /// isn't large enough to contain the agent header, an
    /// agent header that lies about payload size in a way
    /// that later contradicts itself).
    private mutating func drainOne() throws -> SpiceIncomingMessage? {
        while true {
            // Need at least a chunk header to know the body size.
            guard buffer.count >= VDIChunkHeader.byteCount else {
                return nil
            }
            let chunk = try SpiceCodec.decodeChunkHeader(buffer)
            let chunkTotalSize = VDIChunkHeader.byteCount + Int(chunk.size)
            // Wait for the full chunk body to arrive.
            guard buffer.count >= chunkTotalSize else {
                return nil
            }
            let bodyStart = VDIChunkHeader.byteCount
            let bodyEnd = bodyStart + Int(chunk.size)

            if pending == nil {
                // First chunk of a new message — must carry a
                // full agent header at the start of its body.
                guard Int(chunk.size) >= VDAgentMessage.byteCount else {
                    throw SpiceCodec.DecodeError.truncated(
                        expected: VDAgentMessage.byteCount,
                        got: Int(chunk.size)
                    )
                }
                let agent = try SpiceCodec.decodeAgentHeader(
                    buffer.subdata(
                        in: bodyStart..<(bodyStart + VDAgentMessage.byteCount)
                    )
                )
                let payloadStart = bodyStart + VDAgentMessage.byteCount
                let firstChunkPayload = buffer.subdata(
                    in: payloadStart..<bodyEnd
                )
                // Advance past the consumed chunk before any
                // further branching — keeps the error path
                // clean (malformed frames are discarded, not
                // retried forever).
                buffer.removeSubrange(0..<chunkTotalSize)

                // Sanity: a single chunk can't carry MORE
                // payload than the agent claims. If it does,
                // the peer is sending garbage.
                if firstChunkPayload.count > Int(agent.size) {
                    throw SpiceCodec.DecodeError.truncated(
                        expected: Int(agent.size),
                        got: firstChunkPayload.count
                    )
                }

                if firstChunkPayload.count == Int(agent.size) {
                    // Common case: small payload fits in one chunk.
                    return SpiceIncomingMessage(
                        chunk: chunk,
                        agent: agent,
                        payload: firstChunkPayload
                    )
                }

                // Multi-chunk message: start accumulating.
                pending = PendingMessage(
                    firstChunk: chunk,
                    agent: agent,
                    payload: firstChunkPayload
                )
                // Loop to consume the next chunk if already buffered.
                continue
            }

            // Continuation chunk — body is payload bytes only.
            // We're inside the `while true` loop so
            // force-unwrap is safe here.
            var cont = pending!
            let continuationPayload = buffer.subdata(
                in: bodyStart..<bodyEnd
            )
            buffer.removeSubrange(0..<chunkTotalSize)

            // A continuation chunk can't push the accumulated
            // payload past the advertised total.
            let remaining = Int(cont.agent.size) - cont.payload.count
            if continuationPayload.count > remaining {
                pending = nil
                throw SpiceCodec.DecodeError.truncated(
                    expected: Int(cont.agent.size),
                    got: cont.payload.count + continuationPayload.count
                )
            }
            cont.payload.append(continuationPayload)

            if cont.payload.count == Int(cont.agent.size) {
                pending = nil
                return SpiceIncomingMessage(
                    chunk: cont.firstChunk,
                    agent: cont.agent,
                    payload: cont.payload
                )
            }

            pending = cont
            // Keep looping — another continuation chunk may
            // already be in the buffer.
        }
    }
}
