import Foundation
import Testing
@testable import SpooktacularCore

/// Roundtrip coverage for every `AgentFrame` case. The
/// request/response pipeline depends on every kind encoding
/// and decoding to the same value; a silent drift in one
/// case would strand that RPC forever on the host continuation
/// map.
@Suite("AgentFrame")
struct AgentFrameTests {

    @Test("every frame kind roundtrips through AgentFrameCodec")
    func roundtripAllCases() throws {
        let id = UUID()
        let cases: [AgentFrame] = [
            .statsEvent(sampleStats),
            .portsEvent([samplePort]),
            .appsFrontmostEvent(sampleApp),
            .clipboardChangedEvent(.init(text: "hello")),
            .urlOpenedEvent(.init(url: URL(string: "https://example.com")!, originatingApp: "Safari")),
            .logEvent(.init(level: .notice, message: "hello", timestamp: Date(timeIntervalSince1970: 0))),
            .execRequest(requestID: id, .init(command: "ls", timeout: 10)),
            .breakGlassExecRequest(requestID: id, .init(command: "uptime", timeout: 5, ticket: "bgt:...")),
            .clipboardGetRequest(requestID: id),
            .clipboardSetRequest(requestID: id, .init(text: "copy me")),
            .appsListRequest(requestID: id),
            .appsFrontmostRequest(requestID: id),
            .appsLaunchRequest(requestID: id, .init(bundleID: "com.apple.Safari")),
            .appsQuitRequest(requestID: id, .init(bundleID: "com.apple.Safari")),
            .portsListRequest(requestID: id),
            .healthRequest(requestID: id),
            .tunnelOpenRequest(requestID: id, .init(guestPort: 8080)),
            .execResponse(requestID: id, .init(exitCode: 0, stdout: "ok", stderr: "")),
            .clipboardGetResponse(requestID: id, .init(text: "read me")),
            .clipboardSetResponse(requestID: id),
            .appsListResponse(requestID: id, [sampleApp]),
            .appsFrontmostResponse(requestID: id, sampleApp),
            .appsLaunchResponse(requestID: id),
            .appsQuitResponse(requestID: id),
            .portsListResponse(requestID: id, [samplePort]),
            .healthResponse(requestID: id, .init(status: "ok", version: "1.0.0", uptime: 3600)),
            .tunnelOpenResponse(requestID: id, .init(accepted: true)),
            .errorResponse(requestID: id, .init(code: .unsupported, message: "Linux agent cannot launch apps")),
        ]

        for original in cases {
            let encoded = try AgentFrameCodec.encode(original)
            var offset = 0
            let decoded = try AgentFrameCodec.decode(AgentFrame.self) { want in
                defer { offset += want }
                return encoded.subdata(in: offset..<(offset + want))
            }
            #expect(decoded == original, "roundtrip failed for \(original)")
        }
    }

    @Test("request frames carry requestID; events don't")
    func requestIDPresence() {
        let id = UUID()
        #expect(AgentFrame.statsEvent(sampleStats).requestID == nil)
        #expect(AgentFrame.portsEvent([]).requestID == nil)
        #expect(AgentFrame.execRequest(requestID: id, .init(command: "x", timeout: nil)).requestID == id)
        #expect(AgentFrame.errorResponse(requestID: id, .init(code: .timedOut, message: "x")).requestID == id)
    }

    // MARK: - Fixtures

    private var sampleStats: GuestStatsResponse {
        GuestStatsResponse(
            cpuUsage: 0.25,
            memoryUsedBytes: 1 << 30,
            memoryTotalBytes: 16 << 30,
            loadAverage1m: 0.5,
            processCount: 256,
            uptime: 3600
        )
    }

    private var samplePort: GuestPortInfo {
        GuestPortInfo(port: 8080, pid: 1234, processName: "node")
    }

    private var sampleApp: GuestAppInfo {
        GuestAppInfo(name: "Safari", bundleID: "com.apple.Safari", isActive: true, pid: 1000)
    }
}
