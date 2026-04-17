import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("ProcessRunner", .tags(.infrastructure))
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

    @Test("run captures stderr into the thrown error payload")
    func capturesStderrOnFailure() throws {
        // `/bin/sh -c` lets us deterministically write to stderr and
        // exit non-zero in a single process invocation.
        do {
            _ = try ProcessRunner.run(
                "/bin/sh",
                arguments: ["-c", "echo canary-stderr 1>&2; exit 7"]
            )
            Issue.record("Expected ProcessRunnerError but ProcessRunner.run returned")
            return
        } catch let ProcessRunnerError.processFailed(_, stdout, stderr, exitCode) {
            #expect(exitCode == 7)
            #expect(stdout.isEmpty, "stdout must remain empty for this case")
            #expect(stderr.contains("canary-stderr"),
                    "stderr must flow into the error payload instead of /dev/null")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("runAsync captures stdout")
    func asyncCaptures() async throws {
        let output = try await ProcessRunner.runAsync("/bin/echo", arguments: ["world"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "world")
    }
}
