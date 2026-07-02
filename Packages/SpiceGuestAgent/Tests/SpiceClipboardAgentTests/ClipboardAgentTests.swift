import Testing
import Foundation
import SpiceProtocol
@testable import SpiceClipboardAgent

/// In-memory pasteboard double for unit tests. Thread-safe
/// via actor isolation; implements ``PasteboardBridge``.
actor FakePasteboard: PasteboardBridge {
    private var contents: [VDAgentClipboardType: Data] = [:]
    private var counter: Int = 0

    func currentChangeCount() -> Int { counter }

    func availableTypes() -> [VDAgentClipboardType] {
        Array(contents.keys)
    }

    func declaredPasteboardTypes() -> [String] {
        // Synthesise plausible UTIs from the SPICE types in
        // `contents` — enough to satisfy the protocol for
        // tests without actually pulling in AppKit. The
        // text-only bridge only resolves `.utf8Text` in
        // practice; other cases exist for protocol
        // completeness but produce no UTI.
        contents.keys.compactMap { spice in
            spice == .utf8Text ? "public.utf8-plain-text" : nil
        }
    }

    func read(type: VDAgentClipboardType) -> Data? {
        contents[type]
    }

    func write(type: VDAgentClipboardType, data: Data) -> Int {
        contents = [type: data]
        counter += 1
        return counter
    }

    /// Test-only: simulate the user copying something in the
    /// guest without going through the bridge write path.
    func userCopies(_ type: VDAgentClipboardType, _ data: Data) {
        contents = [type: data]
        counter += 1
    }
}

@Suite("SpiceClipboardTypeMapping")
struct TypeMappingTests {

    @Test("Unknown SPICE type has no pasteboard type")
    func unknownMapsNil() {
        #if canImport(AppKit)
        #expect(SpiceClipboardTypeMapping.pasteboardType(for: .none) == nil)
        #endif
    }

    @Test("Only utf8Text maps to an AppKit pasteboard type")
    func textOnlyMapping() {
        #if canImport(AppKit)
        // Text-only bridge: all image types are intentionally
        // unmapped. The enum cases still exist for wire-level
        // decode of peer messages, but we refuse to read or
        // write them against `NSPasteboard`.
        #expect(SpiceClipboardTypeMapping.pasteboardType(for: .utf8Text) != nil)
        #expect(SpiceClipboardTypeMapping.pasteboardType(for: .imagePNG) == nil)
        #expect(SpiceClipboardTypeMapping.pasteboardType(for: .imageTIFF) == nil)
        #expect(SpiceClipboardTypeMapping.pasteboardType(for: .imageJPG) == nil)
        #expect(SpiceClipboardTypeMapping.pasteboardType(for: .imageBMP) == nil)
        #endif
    }
}

@Suite("FakePasteboard behaviour")
struct FakePasteboardTests {

    @Test("Write bumps change count and records contents")
    func writeBumps() async {
        let pb = FakePasteboard()
        #expect(await pb.currentChangeCount() == 0)

        let count1 = await pb.write(type: .utf8Text, data: Data("hi".utf8))
        #expect(count1 == 1)
        #expect(await pb.currentChangeCount() == 1)
        #expect(await pb.read(type: .utf8Text) == Data("hi".utf8))

        let count2 = await pb.write(type: .utf8Text, data: Data("bye".utf8))
        #expect(count2 == 2)
        #expect(await pb.read(type: .utf8Text) == Data("bye".utf8))
    }

    @Test("Clearing via write of new type replaces contents")
    func writeReplacesAllTypes() async {
        let pb = FakePasteboard()
        _ = await pb.write(type: .utf8Text, data: Data("hi".utf8))
        _ = await pb.write(type: .imagePNG, data: Data([0x89, 0x50]))
        let types = await pb.availableTypes()
        #expect(types == [.imagePNG])
        #expect(await pb.read(type: .utf8Text) == nil)
    }
}
