import Testing
import Foundation
@testable import SpiceProtocol

@Suite("VDIChunkHeader")
struct VDIChunkHeaderTests {

    @Test("Encode produces exactly 8 bytes")
    func encodedSize() {
        let header = VDIChunkHeader(port: 1, size: 42)
        let data = SpiceCodec.encode(chunk: header)
        #expect(data.count == VDIChunkHeader.byteCount)
        #expect(data.count == 8)
    }

    @Test("Little-endian byte order on the wire")
    func endianness() {
        // 0x01020304 little-endian = [04, 03, 02, 01]
        let header = VDIChunkHeader(port: 1, size: 0x01020304)
        let data = SpiceCodec.encode(chunk: header)
        // port field (first 4 bytes) should be [01, 00, 00, 00].
        #expect(Array(data[0..<4]) == [0x01, 0x00, 0x00, 0x00])
        // size field (next 4 bytes) should be [04, 03, 02, 01].
        #expect(Array(data[4..<8]) == [0x04, 0x03, 0x02, 0x01])
    }

    @Test("Round-trip preserves all fields")
    func roundTrip() throws {
        let original = VDIChunkHeader(port: 2, size: 0xDEADBEEF)
        let encoded = SpiceCodec.encode(chunk: original)
        let decoded = try SpiceCodec.decodeChunkHeader(encoded)
        #expect(decoded == original)
    }

    @Test("Truncated input throws")
    func truncation() {
        let tooShort = Data([0x01, 0x00, 0x00])
        #expect(throws: SpiceCodec.DecodeError.self) {
            try SpiceCodec.decodeChunkHeader(tooShort)
        }
    }
}

@Suite("VDAgentMessage")
struct VDAgentMessageTests {

    @Test("Encode produces exactly 20 bytes")
    func encodedSize() {
        let header = VDAgentMessage(
            type: .clipboardGrab,
            size: 16
        )
        let data = SpiceCodec.encode(message: header)
        #expect(data.count == VDAgentMessage.byteCount)
        #expect(data.count == 20)
    }

    @Test("Protocol version defaults to 1")
    func protocolVersionDefault() {
        let header = VDAgentMessage(type: .clipboard, size: 0)
        #expect(header.protocolVersion == 1)
    }

    @Test("Round-trip preserves all fields")
    func roundTrip() throws {
        let original = VDAgentMessage(
            protocolVersion: 1,
            type: VDAgentMessageType.clipboardRequest.rawValue,
            opaque: 0xCAFEBABE_DEADBEEF,
            size: 8
        )
        let encoded = SpiceCodec.encode(message: original)
        let decoded = try SpiceCodec.decodeAgentHeader(encoded)
        #expect(decoded == original)
    }

    @Test("Unsupported protocol version rejected")
    func unsupportedProtocol() {
        var data = Data(capacity: 20)
        data.appendLE(UInt32(999))  // bogus protocol
        data.appendLE(UInt32(7))
        data.appendLE(UInt64(0))
        data.appendLE(UInt32(0))
        #expect(throws: SpiceCodec.DecodeError.self) {
            try SpiceCodec.decodeAgentHeader(data)
        }
    }
}

@Suite("Frame composition")
struct FrameTests {

    @Test("Frame wraps chunk + agent + payload in that order")
    func frameLayout() throws {
        let payload = Data("hello".utf8)
        let frame = SpiceCodec.frame(
            type: .clipboard,
            payload: payload
        )
        // Total = chunk(8) + agent(20) + payload(5) = 33
        #expect(frame.count == 33)

        // Chunk header's size covers agent + payload (25).
        let chunk = try SpiceCodec.decodeChunkHeader(frame)
        #expect(chunk.port == VDIChunkHeader.clientPort)
        #expect(chunk.size == 25)

        // Agent header sits at offset 8.
        let agentSlice = frame.subdata(in: 8..<28)
        let agent = try SpiceCodec.decodeAgentHeader(agentSlice)
        #expect(agent.type == VDAgentMessageType.clipboard.rawValue)
        #expect(agent.size == 5)

        // Payload trails.
        #expect(frame.subdata(in: 28..<33) == payload)
    }
}
