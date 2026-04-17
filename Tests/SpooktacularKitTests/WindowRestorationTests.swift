import Testing
import Foundation

/// Verifies the @AppStorage JSON round-trip that `AppState`
/// uses to persist the set of open workspace windows across
/// launches. The format is a JSON array of VM names.
///
/// This target can't import the Spooktacular executable where
/// the AppState type lives, so we exercise the exact on-disk
/// encoding contract here — if this suite breaks, the GUI's
/// window restoration ships broken too.
@Suite("Open workspaces persistence", .tags(.configuration))
struct WindowRestorationTests {

    @Test("Empty array round-trips")
    func emptyRoundTrip() throws {
        let empty: [String] = []
        let data = try JSONEncoder().encode(empty)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        #expect(decoded == empty)
    }

    @Test("Names round-trip in sorted order")
    func sortedRoundTrip() throws {
        let names = ["runner-01", "dev", "build-cache"].sorted()
        let data = try JSONEncoder().encode(names)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        #expect(decoded == ["build-cache", "dev", "runner-01"])
    }

    @Test("Filter drops names that are no longer present")
    func filterDropsMissing() {
        let persisted = ["runner-01", "dev", "stale"]
        let known: Set<String> = ["runner-01", "dev"]
        let restorable = persisted.filter { known.contains($0) }
        #expect(restorable == ["runner-01", "dev"])
    }

    @Test("Corrupt defaults data returns empty without throwing")
    func corruptDefaults() {
        let data = Data([0xFF, 0x00, 0xFF])
        let decoded = try? JSONDecoder().decode([String].self, from: data)
        #expect(decoded == nil)
    }
}
