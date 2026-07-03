import Testing
import Foundation
@testable import SpooktacularCore

// MARK: - Guest Agent Model Round-Trip Tests

@Suite("Guest Agent Models", .tags(.security, .integration))
struct GuestAgentModelTests {

    @Test("AppInfo round-trips through JSON")
    func appInfoRoundTrip() throws {
        let info = GuestAppInfo(name: "Safari", bundleID: "com.apple.Safari", isActive: true, pid: 123)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(GuestAppInfo.self, from: data)
        #expect(decoded.name == "Safari")
        #expect(decoded.bundleID == "com.apple.Safari")
        #expect(decoded.isActive == true)
        #expect(decoded.pid == 123)
    }

    @Test("PortInfo round-trips through JSON")
    func portInfoRoundTrip() throws {
        let info = GuestPortInfo(port: 8080, pid: 456, processName: "node")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(GuestPortInfo.self, from: data)
        #expect(decoded.port == 8080)
        #expect(decoded.pid == 456)
        #expect(decoded.processName == "node")
    }
}
