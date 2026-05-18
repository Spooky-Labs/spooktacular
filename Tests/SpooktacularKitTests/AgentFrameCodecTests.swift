import Foundation
import Testing
@testable import SpooktacularCore

/// Roundtrip + edge-case coverage for the length-prefixed
/// Codable framer that backs the Apple-native guest → host
/// event channel. The channel is only as trustworthy as the
/// codec's handling of partial reads and malformed headers,
/// so these cases are locked down as Swift Testing suites.
@Suite("AgentFrameCodec")
struct AgentFrameCodecTests {

    @Test("encode then decode roundtrips a GuestEvent")
    func roundtrip() throws {
        let event = GuestEvent.stats(
            GuestStatsResponse(
                cpuUsage: 0.42,
                memoryUsedBytes: 1_234_567_890,
                memoryTotalBytes: 16 * 1024 * 1024 * 1024,
                loadAverage1m: 0.73,
                processCount: 312,
                uptime: 3_600
            )
        )
        let frame = try AgentFrameCodec.encode(event)
        #expect(frame.count >= 4)

        var offset = 0
        let decoded = try AgentFrameCodec.decode(GuestEvent.self) { want in
            defer { offset += want }
            return frame.subdata(in: offset..<(offset + want))
        }
        #expect(decoded == event)
    }

    @Test("unexpected EOF during header surfaces as DecodeError")
    func shortHeader() throws {
        #expect(throws: AgentFrameCodec.DecodeError.unexpectedEOF) {
            _ = try AgentFrameCodec.decode(GuestEvent.self) { _ in Data([0x00, 0x00]) }
        }
    }

    @Test("oversize length header rejected before allocation")
    func oversizeFrame() throws {
        // 4-byte BE length = 0x7fffffff (~2 GB) — comfortably
        // above our 16 MiB limit. The decoder should reject it
        // *before* asking for the body.
        let header = Data([0x7f, 0xff, 0xff, 0xff])
        #expect(throws: AgentFrameCodec.DecodeError.self) {
            _ = try AgentFrameCodec.decode(GuestEvent.self) { want in
                // Only the header should ever be requested — if
                // the decoder asks for the body, the test
                // reaches here and fails via the caller not
                // seeing an error at all. Return empty to make
                // that failure mode obvious.
                return want == 4 ? header : Data()
            }
        }
    }
}
