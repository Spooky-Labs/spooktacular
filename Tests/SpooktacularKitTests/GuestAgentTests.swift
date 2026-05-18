import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

// MARK: - Guest Agent Model Round-Trip Tests

@Suite("Guest Agent Models", .tags(.security, .integration))
struct GuestAgentModelTests {

    @Test("ExecResponse round-trips through JSON")
    func execResponseRoundTrip() throws {
        let response = GuestExecResponse(exitCode: 0, stdout: "hello", stderr: "")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(GuestExecResponse.self, from: data)
        #expect(decoded.exitCode == 0)
        #expect(decoded.stdout == "hello")
        #expect(decoded.stderr == "")
    }

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

    @Test("FSEntry round-trips through JSON")
    func fsEntryRoundTrip() throws {
        let entry = GuestFSEntry(name: "Documents", isDirectory: true, size: 0)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(GuestFSEntry.self, from: data)
        #expect(decoded.name == "Documents")
        #expect(decoded.isDirectory == true)
        #expect(decoded.size == 0)
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

    @Test("HealthResponse round-trips through JSON")
    func healthRoundTrip() throws {
        let response = GuestHealthResponse(status: "ok", version: "1.0.0", uptime: 42.5)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(GuestHealthResponse.self, from: data)
        #expect(decoded.status == "ok")
        #expect(decoded.version == "1.0.0")
        #expect(decoded.uptime == 42.5)
    }

    @Test("FileInfo round-trips through JSON")
    func fileInfoRoundTrip() throws {
        let info = GuestFileInfo(name: "test.txt", data: "aGVsbG8=")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(GuestFileInfo.self, from: data)
        #expect(decoded.name == "test.txt")
        #expect(decoded.data == "aGVsbG8=")
    }
}

// MARK: - Guest Agent Error Tests

@Suite("Guest Agent Errors", .tags(.security, .integration))
struct GuestAgentErrorTests {

    @Test("all error cases have non-empty descriptions and recovery suggestions",
          arguments: [
              GuestAgentError.notConnected,
              GuestAgentError.httpError(statusCode: 500, message: "fail"),
              GuestAgentError.invalidResponse,
              GuestAgentError.timeout,
          ])
    func descriptionsPresent(error: GuestAgentError) {
        #expect(error.errorDescription != nil)
        #expect(!error.errorDescription!.isEmpty)
        #expect(error.recoverySuggestion != nil)
        #expect(!error.recoverySuggestion!.isEmpty)
    }

    @Test("httpError includes status code and message in description")
    func httpErrorDetail() {
        let error = GuestAgentError.httpError(statusCode: 404, message: "Not found")
        let description = error.errorDescription ?? ""
        #expect(description.contains("404"))
        #expect(description.contains("Not found"))
    }

    @Test("notConnected suggests installing the agent")
    func notConnectedSuggestion() {
        let error = GuestAgentError.notConnected
        #expect(error.recoverySuggestion?.contains("spooktacular-agent") == true)
    }

    @Test("invalidResponse suggests updating the agent")
    func invalidResponseSuggestion() {
        let error = GuestAgentError.invalidResponse
        let suggestion = error.recoverySuggestion ?? ""
        #expect(suggestion.lowercased().contains("update"))
    }
}
