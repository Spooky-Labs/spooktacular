import Testing
import Foundation
@testable import SpiceProtocol

@Suite("Announce Capabilities")
struct AnnounceCapabilitiesTests {

    @Test("Mac-guest default set has exactly the documented bits")
    func macGuestDefaults() {
        let caps = VDAgentCapabilities.macGuestDefault
        // Intentionally omitted: mouseState, monitorsConfig,
        // displayConfig, guestLineendCRLF, audioVolumeSync,
        // graphicsDeviceInfo, maxClipboard (no matching
        // VDAgentMaxClipboard message sender implemented —
        // don't advertise a cap we can't honor).
        #expect(!caps.contains(.mouseState))
        #expect(!caps.contains(.monitorsConfig))
        #expect(!caps.contains(.displayConfig))
        #expect(!caps.contains(.guestLineendCRLF))
        #expect(!caps.contains(.maxClipboard))
        // Present:
        #expect(caps.contains(.reply))
        // `.clipboard` (bit 3) is the legacy push-model cap
        // every deployed SPICE peer advertises as a
        // prerequisite for the modern extensions
        // (`clipboardByDemand`, `clipboardSelection`) — we
        // announce both so servers that gate on the legacy
        // bit don't silently drop our REQUESTs.
        #expect(caps.contains(.clipboard))
        #expect(caps.contains(.clipboardByDemand))
        #expect(caps.contains(.clipboardSelection))
        #expect(caps.contains(.guestLineendLF))
        #expect(caps.contains(.clipboardNoReleaseOnRegrab))
        #expect(caps.contains(.clipboardGrabSerial))
    }

    @Test("Round-trip request=true")
    func roundTripRequest() throws {
        let original = VDAgentAnnounceCapabilities(
            request: true,
            capabilities: .macGuestDefault
        )
        let encoded = original.encode()
        let decoded = try VDAgentAnnounceCapabilities.decode(payload: encoded)
        #expect(decoded == original)
    }

    @Test("Round-trip request=false")
    func roundTripReply() throws {
        let original = VDAgentAnnounceCapabilities(
            request: false,
            capabilities: [.reply, .clipboardByDemand]
        )
        let encoded = original.encode()
        let decoded = try VDAgentAnnounceCapabilities.decode(payload: encoded)
        #expect(decoded == original)
    }

    @Test("Truncated payload throws")
    func truncation() {
        let tiny = Data([0x01, 0x00])
        #expect(throws: SpiceCodec.DecodeError.self) {
            try VDAgentAnnounceCapabilities.decode(payload: tiny)
        }
    }
}

@Suite("Clipboard GRAB")
struct ClipboardGrabTests {

    @Test("Round-trip with serial")
    func roundTripSerial() throws {
        let original = VDAgentClipboardMessage.Grab(
            selection: .clipboard,
            types: [.utf8Text, .imagePNG],
            serial: 42
        )
        let encoded = original.encode()
        let decoded = try VDAgentClipboardMessage.Grab.decode(
            payload: encoded,
            hasSerial: true
        )
        #expect(decoded == original)
    }

    @Test("Round-trip without serial (legacy peer)")
    func roundTripNoSerial() throws {
        let original = VDAgentClipboardMessage.Grab(
            selection: .clipboard,
            types: [.utf8Text],
            serial: nil
        )
        let encoded = original.encode()
        let decoded = try VDAgentClipboardMessage.Grab.decode(
            payload: encoded,
            hasSerial: false
        )
        #expect(decoded == original)
    }

    @Test("Selection prefix is 4 bytes (1 + 3 reserved)")
    func selectionPrefix() {
        let grab = VDAgentClipboardMessage.Grab(
            selection: .clipboard,
            types: []
        )
        let encoded = grab.encode()
        // 4 bytes selection + 0 types = 4 bytes total.
        #expect(encoded.count == 4)
        #expect(encoded[0] == VDAgentClipboardSelection.clipboard.rawValue)
        #expect(encoded[1] == 0)
        #expect(encoded[2] == 0)
        #expect(encoded[3] == 0)
    }

    @Test("Unknown clipboard types in peer's grab are skipped")
    func forwardCompat() throws {
        // Build a grab manually with a known + unknown type.
        var payload = Data()
        payload.appendLE(VDAgentClipboardSelection.clipboard.rawValue)
        payload.append(contentsOf: [0, 0, 0])
        payload.appendLE(VDAgentClipboardType.utf8Text.rawValue)
        payload.appendLE(UInt32(9999))  // unknown type
        payload.appendLE(VDAgentClipboardType.imagePNG.rawValue)

        let decoded = try VDAgentClipboardMessage.Grab.decode(
            payload: payload,
            hasSerial: false
        )
        // Known types survive, unknown silently dropped.
        #expect(decoded.types == [.utf8Text, .imagePNG])
    }
}

@Suite("Clipboard REQUEST / DATA / RELEASE")
struct ClipboardRoundTripTests {

    @Test("Request round-trip")
    func request() throws {
        let original = VDAgentClipboardMessage.Request(
            selection: .clipboard,
            type: .utf8Text
        )
        let encoded = original.encode()
        #expect(encoded.count == 8)
        let decoded = try VDAgentClipboardMessage.Request.decode(
            payload: encoded
        )
        #expect(decoded == original)
    }

    @Test("Data payload round-trip — text")
    func dataText() throws {
        let text = "Hello from the guest 👋"
        let original = VDAgentClipboardMessage.Payload(
            selection: .clipboard,
            type: .utf8Text,
            data: Data(text.utf8)
        )
        let encoded = original.encode()
        let decoded = try VDAgentClipboardMessage.Payload.decode(
            payload: encoded
        )
        #expect(decoded == original)
        #expect(String(data: decoded.data, encoding: .utf8) == text)
    }

    @Test("Data payload round-trip — image")
    func dataImage() throws {
        // Pretend PNG — a few bytes is enough for framing.
        let imageBytes = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        ])
        let original = VDAgentClipboardMessage.Payload(
            selection: .clipboard,
            type: .imagePNG,
            data: imageBytes
        )
        let encoded = original.encode()
        let decoded = try VDAgentClipboardMessage.Payload.decode(
            payload: encoded
        )
        #expect(decoded.data == imageBytes)
        #expect(decoded.type == .imagePNG)
    }

    @Test("Release round-trip")
    func release() throws {
        let original = VDAgentClipboardMessage.Release(
            selection: .clipboard
        )
        let encoded = original.encode()
        #expect(encoded.count == 4)
        let decoded = try VDAgentClipboardMessage.Release.decode(
            payload: encoded
        )
        #expect(decoded == original)
    }

    @Test("Unknown selection byte rejected")
    func unknownSelection() {
        var bogus = Data([0xFF, 0, 0, 0])  // selection 0xFF — unknown
        bogus.appendLE(VDAgentClipboardType.utf8Text.rawValue)
        #expect(throws: SpiceCodec.DecodeError.self) {
            try VDAgentClipboardMessage.Request.decode(payload: bogus)
        }
    }
}
