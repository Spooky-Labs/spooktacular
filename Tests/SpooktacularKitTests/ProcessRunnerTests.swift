import Testing
import Foundation
@testable import SpooktacularKit

@Suite("ProcessRunner")
struct ProcessRunnerTests {

    @Test("run captures stdout")
    func capturesStdout() throws {
        let output = try ProcessRunner.run("/bin/echo", arguments: ["hello"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test("run throws on nonzero exit")
    func throwsOnFailure() {
        #expect(throws: ProcessRunnerError.self) {
            _ = try ProcessRunner.run("/usr/bin/false", arguments: [])
        }
    }

    @Test("runAsync captures stdout")
    func asyncCaptures() async throws {
        let output = try await ProcessRunner.runAsync("/bin/echo", arguments: ["world"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "world")
    }
}
