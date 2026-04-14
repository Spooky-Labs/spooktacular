import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

// MARK: - Guest Agent Model Round-Trip Tests

@Suite("GuestAgentModels")
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

    @Test("AppInfo round-trips")
    func appInfoRoundTrip() throws {
        let info = GuestAppInfo(name: "Safari", bundleID: "com.apple.Safari", isActive: true, pid: 123)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(GuestAppInfo.self, from: data)
        #expect(decoded.name == "Safari")
        #expect(decoded.bundleID == "com.apple.Safari")
        #expect(decoded.isActive == true)
        #expect(decoded.pid == 123)
    }

    @Test("FSEntry round-trips")
    func fsEntryRoundTrip() throws {
        let entry = GuestFSEntry(name: "Documents", isDirectory: true, size: 0)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(GuestFSEntry.self, from: data)
        #expect(decoded.name == "Documents")
        #expect(decoded.isDirectory == true)
        #expect(decoded.size == 0)
    }

    @Test("PortInfo round-trips")
    func portInfoRoundTrip() throws {
        let info = GuestPortInfo(port: 8080, pid: 456, processName: "node")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(GuestPortInfo.self, from: data)
        #expect(decoded.port == 8080)
        #expect(decoded.pid == 456)
        #expect(decoded.processName == "node")
    }

    @Test("HealthResponse round-trips")
    func healthRoundTrip() throws {
        let response = GuestHealthResponse(status: "ok", version: "1.0.0", uptime: 42.5)
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(GuestHealthResponse.self, from: data)
        #expect(decoded.status == "ok")
        #expect(decoded.version == "1.0.0")
        #expect(decoded.uptime == 42.5)
    }

    @Test("FileInfo round-trips")
    func fileInfoRoundTrip() throws {
        let info = GuestFileInfo(name: "test.txt", data: "aGVsbG8=")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(GuestFileInfo.self, from: data)
        #expect(decoded.name == "test.txt")
        #expect(decoded.data == "aGVsbG8=")
    }
}

// MARK: - Guest Agent Error Tests

@Suite("GuestAgentError")
struct GuestAgentErrorTests {

    @Test("All cases have descriptions")
    func descriptions() {
        let errors: [GuestAgentError] = [
            .notConnected,
            .httpError(statusCode: 500, message: "fail"),
            .invalidResponse,
            .timeout,
        ]
        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
            #expect(error.recoverySuggestion != nil)
            #expect(!error.recoverySuggestion!.isEmpty)
        }
    }

    @Test("httpError includes status code in description")
    func httpErrorDetail() {
        let error = GuestAgentError.httpError(statusCode: 404, message: "Not found")
        #expect(error.errorDescription!.contains("404"))
    }

    @Test("httpError includes message in description")
    func httpErrorMessage() {
        let error = GuestAgentError.httpError(statusCode: 500, message: "Internal error")
        #expect(error.errorDescription!.contains("Internal error"))
    }

    @Test("notConnected suggests installing the agent")
    func notConnectedSuggestion() {
        let error = GuestAgentError.notConnected
        #expect(error.recoverySuggestion!.contains("spooktacular-agent"))
    }

    @Test("invalidResponse suggests updating the agent")
    func invalidResponseSuggestion() {
        let error = GuestAgentError.invalidResponse
        #expect(error.recoverySuggestion!.lowercased().contains("update"))
    }
}
