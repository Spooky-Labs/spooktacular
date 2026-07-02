import Testing
import Foundation
import SpiceProtocol
@testable import SpiceSerialTransport

@Suite("SpiceFramer reassembly")
struct FramerTests {

    /// Helper: builds a complete on-wire frame for a known
    /// message so tests can inject arbitrary byte slices.
    private func frame(
        type: VDAgentMessageType,
        payload: Data
    ) -> Data {
        SpiceCodec.frame(type: type, payload: payload)
    }

    @Test("Whole frame in one read")
    func wholeFrame() throws {
        var framer = SpiceFramer()
        let f = frame(type: .clipboardGrab, payload: Data([1, 2, 3, 4]))
        let messages = try framer.ingest(f)
        #expect(messages.count == 1)
        #expect(messages[0].type == .clipboardGrab)
        #expect(messages[0].payload == Data([1, 2, 3, 4]))
    }

    @Test("Two whole frames in one read")
    func twoWholeFrames() throws {
        var framer = SpiceFramer()
        var combined = Data()
        combined.append(frame(type: .clipboardGrab, payload: Data([1])))
        combined.append(frame(type: .clipboardRelease, payload: Data([2])))
        let messages = try framer.ingest(combined)
        #expect(messages.count == 2)
        #expect(messages[0].type == .clipboardGrab)
        #expect(messages[0].payload == Data([1]))
        #expect(messages[1].type == .clipboardRelease)
        #expect(messages[1].payload == Data([2]))
    }

    @Test("Frame split across two reads (header boundary)")
    func splitAtHeader() throws {
        var framer = SpiceFramer()
        let f = frame(type: .clipboardGrab, payload: Data([1, 2, 3]))
        // Split mid-chunk-header.
        let first = framer.ingestUnchecked(f.subdata(in: 0..<4))
        #expect(first.isEmpty)
        let rest = try framer.ingest(f.subdata(in: 4..<f.count))
        #expect(rest.count == 1)
        #expect(rest[0].payload == Data([1, 2, 3]))
    }

    @Test("Frame split across two reads (payload boundary)")
    func splitAtPayload() throws {
        var framer = SpiceFramer()
        let f = frame(type: .clipboardGrab, payload: Data([10, 20, 30, 40]))
        // Split inside the payload — first chunk carries
        // chunk+agent headers plus the first 2 payload bytes.
        let headerEnd = VDIChunkHeader.byteCount
            + VDAgentMessage.byteCount + 2
        let first = try framer.ingest(f.subdata(in: 0..<headerEnd))
        #expect(first.isEmpty)
        let rest = try framer.ingest(f.subdata(in: headerEnd..<f.count))
        #expect(rest.count == 1)
        #expect(rest[0].payload == Data([10, 20, 30, 40]))
    }

    @Test("Back-to-back single-byte reads still reassemble")
    func byteAtATime() throws {
        var framer = SpiceFramer()
        let f = frame(type: .clipboard, payload: Data("hi".utf8))
        var messages: [SpiceIncomingMessage] = []
        for byte in f {
            messages.append(contentsOf: try framer.ingest(Data([byte])))
        }
        #expect(messages.count == 1)
        #expect(messages[0].payload == Data("hi".utf8))
    }

    @Test("Malformed chunk size throws")
    func malformedChunk() {
        var framer = SpiceFramer()
        // Chunk says size = 0, which is less than agent-header size.
        var bogus = Data()
        bogus.appendLE(UInt32(1))  // port
        bogus.appendLE(UInt32(0))  // size (invalid)
        #expect(throws: SpiceCodec.DecodeError.self) {
            try framer.ingest(bogus)
        }
    }

    // MARK: - Multi-chunk reassembly

    /// Regression: screenshot-sized payloads span thousands
    /// of continuation chunks (payload > 2 KB triggers
    /// fragmentation per `VD_AGENT_MAX_DATA_SIZE = 2048` in
    /// `spice/vd_agent.h`). Before the reassembly fix, the
    /// framer treated the first chunk's body as the whole
    /// message and threw `truncated` when `agent.size`
    /// exceeded `chunk.size`. This kept text clipboard
    /// working (fit in one chunk) but broke images entirely.
    @Test("Large payload spanning many chunks reassembles intact")
    func multiChunkLargePayload() throws {
        var framer = SpiceFramer()
        // 1 MB payload — well past 2 KB cap; ~512 chunks.
        let payload = Data((0..<(1024 * 1024)).map { UInt8($0 & 0xFF) })
        let f = frame(type: .clipboard, payload: payload)
        // Produces multiple chunks glued end-to-end in `f`.
        // Sanity-check the outbound side while we're at it.
        let expectedChunks = 1 + (payload.count - (SpiceCodec.maxChunkBodySize - VDAgentMessage.byteCount) + SpiceCodec.maxChunkBodySize - 1) / SpiceCodec.maxChunkBodySize
        #expect(expectedChunks > 500)

        let messages = try framer.ingest(f)
        #expect(messages.count == 1)
        #expect(messages[0].type == .clipboard)
        #expect(messages[0].payload == payload)
    }

    @Test("Multi-chunk message arriving in torn-up reads still reassembles")
    func multiChunkTornReads() throws {
        var framer = SpiceFramer()
        // Tune to exercise both "chunk split across reads"
        // (the single-chunk case) and "message split across
        // chunks" (the multi-chunk case) — pick a payload
        // size that forces 3 chunks.
        let payloadSize = SpiceCodec.maxChunkBodySize * 2 + 100
        let payload = Data((0..<payloadSize).map { UInt8($0 & 0xFF) })
        let f = frame(type: .clipboard, payload: payload)

        // Break the wire bytes into seven arbitrary slices
        // that don't align to chunk boundaries.
        let slices: [Data] = stride(from: 0, to: f.count, by: 777).map {
            let end = Swift.min($0 + 777, f.count)
            return f.subdata(in: $0..<end)
        }

        var messages: [SpiceIncomingMessage] = []
        for slice in slices {
            messages.append(contentsOf: try framer.ingest(slice))
        }
        #expect(messages.count == 1)
        #expect(messages[0].payload == payload)
    }

    @Test("Two consecutive multi-chunk messages are framed independently")
    func multiChunkBackToBack() throws {
        var framer = SpiceFramer()
        let payloadA = Data(repeating: 0xAA, count: 8_000)
        let payloadB = Data(repeating: 0xBB, count: 10_000)

        var wire = Data()
        wire.append(frame(type: .clipboard, payload: payloadA))
        wire.append(frame(type: .clipboard, payload: payloadB))

        let messages = try framer.ingest(wire)
        #expect(messages.count == 2)
        #expect(messages[0].payload == payloadA)
        #expect(messages[1].payload == payloadB)
    }

    @Test("Empty-payload message still produces exactly one chunk")
    func emptyPayloadStillEmitsOneChunk() throws {
        var framer = SpiceFramer()
        let f = frame(type: .clipboardRelease, payload: Data())
        #expect(f.count == VDIChunkHeader.byteCount + VDAgentMessage.byteCount)

        let messages = try framer.ingest(f)
        #expect(messages.count == 1)
        #expect(messages[0].type == .clipboardRelease)
        #expect(messages[0].payload.isEmpty)
    }
}

// Test-only convenience: `ingest` that doesn't throw because
// the test is specifically checking the partial-buffer case
// where no complete message exists yet and no error can occur.
// Keeps test assertions readable.
extension SpiceFramer {
    mutating func ingestUnchecked(_ data: Data) -> [SpiceIncomingMessage] {
        (try? ingest(data)) ?? []
    }
}

// Local helper — duplicated from the main package's internal
// Data+LE extension so tests don't need @testable access to
// that file. Keeps coupling one-way.
fileprivate extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { raw in
            append(contentsOf: raw)
        }
    }
}
