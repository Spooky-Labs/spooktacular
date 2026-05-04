import Foundation
import Testing
@testable import SpooktacularCore

/// Round-trip + edge-case coverage for the streaming wire
/// protocol. The frame codec is on the 60 fps hot path, so
/// every invariant that would silently corrupt a client
/// stream — magic mismatch, length underflow, partial buffer
/// behaviour, big-endian endian drift — is pinned here.
@Suite("VMStreamingProtocol", .tags(.infrastructure))
struct VMStreamingProtocolTests {

    @Test("Frame round-trips through encoded() + parseVMStreamingFrame")
    func roundTrip() throws {
        let payload = try VMStreamingCodec.encode(
            VMMetricsSnapshot(
                at: Date(timeIntervalSince1970: 1_800_000_000),
                cpuUsage: 0.42,
                memoryUsedBytes: 4 * 1024 * 1024 * 1024,
                memoryTotalBytes: 16 * 1024 * 1024 * 1024,
                loadAverage1m: 1.7,
                processCount: 512,
                uptime: 3600
            )
        )
        let frame = VMStreamingFrame(
            kind: .event,
            topic: 42,
            payload: payload
        )

        var wire = frame.encoded()
        let decoded = try #require(try parseVMStreamingFrame(from: &wire))
        #expect(decoded.kind == .event)
        #expect(decoded.topic == 42)
        #expect(decoded.payload == payload)
        #expect(wire.isEmpty, "All bytes consumed")
    }

    @Test("Partial buffer returns nil; completing the buffer yields the frame")
    func partialBuffer() throws {
        let frame = VMStreamingFrame(kind: .heartbeat, topic: 0)
        let wire = frame.encoded()

        // Feed bytes one at a time. Every prefix shorter than
        // the full frame must return nil; the exact length
        // yields the frame.
        for cut in 0..<wire.count {
            var partial = wire[wire.startIndex..<wire.startIndex + cut]
            #expect(try parseVMStreamingFrame(from: &partial) == nil,
                "Partial prefix of length \(cut) must not parse a complete frame")
        }

        var complete = wire
        let decoded = try #require(try parseVMStreamingFrame(from: &complete))
        #expect(decoded == frame)
        #expect(complete.isEmpty)
    }

    @Test("Multiple frames concatenated parse in order")
    func multipleFramesBackToBack() throws {
        let a = VMStreamingFrame(kind: .ack, topic: 1, payload: Data([1, 2, 3]))
        let b = VMStreamingFrame(kind: .event, topic: 1, payload: Data([4, 5]))
        let c = VMStreamingFrame(kind: .heartbeat, topic: 0)

        var wire = a.encoded() + b.encoded() + c.encoded()
        let first = try #require(try parseVMStreamingFrame(from: &wire))
        let second = try #require(try parseVMStreamingFrame(from: &wire))
        let third = try #require(try parseVMStreamingFrame(from: &wire))
        #expect(first == a)
        #expect(second == b)
        #expect(third == c)
        #expect(wire.isEmpty)
    }

    @Test("Wrong magic bytes throw protocolMismatch")
    func wrongMagic() throws {
        var wire = Data([0x00, 0x00, 0x00, 0x00,        // bad magic
                         0x00, 0x00, 0x00, 0x05,        // length
                         0x06, 0x00, 0x00, 0x00, 0x00]) // heartbeat/topic0
        #expect(throws: VMStreamingError.self) {
            _ = try parseVMStreamingFrame(from: &wire)
        }
    }

    @Test("Unknown frame kind throws protocolMismatch")
    func unknownFrameKind() throws {
        // Build a valid header with a kind byte that's not in
        // the enum (0xFF).
        var frame = VMStreamingFrame(kind: .event, topic: 0, payload: Data())
        var wire = frame.encoded()
        // Kind byte sits at offset 8 (magic:4 + length:4).
        wire[wire.startIndex + 8] = 0xFF

        #expect(throws: VMStreamingError.self) {
            _ = try parseVMStreamingFrame(from: &wire)
        }

        // Silence the unused-variable warning on `frame` without
        // losing the comment.
        _ = frame
    }

    @Test("Binary-plist codec round-trips every event payload")
    func payloadCodecRoundTrip() throws {
        // `VMStreamSubscribeRequest`
        let subscribe = VMStreamSubscribeRequest(topic: .metrics)
        let subscribeBytes = try VMStreamingCodec.encode(subscribe)
        #expect(try VMStreamingCodec.decode(VMStreamSubscribeRequest.self, from: subscribeBytes) == subscribe)

        // `VMLifecycleEvent`
        let lifecycle = VMLifecycleEvent(at: Date(timeIntervalSince1970: 1_800_000_000), state: "running")
        let lifecycleBytes = try VMStreamingCodec.encode(lifecycle)
        #expect(try VMStreamingCodec.decode(VMLifecycleEvent.self, from: lifecycleBytes) == lifecycle)

        // `VMPortsSnapshot`
        let ports = VMPortsSnapshot(
            at: Date(timeIntervalSince1970: 1_800_000_000),
            ports: [
                .init(port: 8080, processName: "node"),
                .init(port: 5432, processName: "postgres"),
            ]
        )
        let portsBytes = try VMStreamingCodec.encode(ports)
        #expect(try VMStreamingCodec.decode(VMPortsSnapshot.self, from: portsBytes) == ports)

        // `VMStreamingError`
        let err = VMStreamingError(code: .vmStopped, reason: "the VM stopped")
        let errBytes = try VMStreamingCodec.encode(err)
        #expect(try VMStreamingCodec.decode(VMStreamingError.self, from: errBytes) == err)
    }

    @Test("Frame size accounting — length field counts bytes AFTER it, not total")
    func lengthFieldAccounting() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let frame = VMStreamingFrame(kind: .event, topic: 99, payload: payload)
        let wire = frame.encoded()

        // Header is magic:4 + length:4 + kind:1 + topic:4 = 13.
        // Length field at [4..<8] should equal kind+topic+payload = 1+4+3 = 8.
        let lengthByte0 = wire[wire.startIndex + 4]
        let lengthByte1 = wire[wire.startIndex + 5]
        let lengthByte2 = wire[wire.startIndex + 6]
        let lengthByte3 = wire[wire.startIndex + 7]
        let length = UInt32(lengthByte0) << 24
            | UInt32(lengthByte1) << 16
            | UInt32(lengthByte2) << 8
            | UInt32(lengthByte3)
        #expect(length == 8, "length counts bytes after the length field")

        // Total wire size = 8 + length = 16.
        #expect(wire.count == 16)
    }
}
