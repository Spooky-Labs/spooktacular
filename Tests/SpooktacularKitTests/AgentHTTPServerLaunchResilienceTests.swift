import Foundation
import Testing

/// Regression test for the Phase-4-late bug where
/// `AgentHTTPServer.acceptLoop` called `exit(1)` on vsock
/// bind / listen failure — appropriate for the legacy
/// `@main` CLI daemon, fatal for the SwiftUI guest-tools
/// app (would kill the SPICE clipboard bridge the moment
/// the app launched outside a VZ guest context, e.g. on
/// the host for developer iteration).
///
/// The contract we want to pin: `acceptLoop` + `listenAll`
/// never `exit(N)` the process; failures return from the
/// function so the caller can handle them.
///
/// We can't easily integration-test vsock bind failure in
/// a unit environment, so this test catches the class of
/// regression at the grep level: no `exit(` call in the
/// accept-loop code path.
@Suite("AgentHTTPServer launch resilience")
struct AgentHTTPServerLaunchResilienceTests {

    @Test("acceptLoop never calls exit() on socket setup failure")
    func acceptLoopDoesNotExitOnFailure() throws {
        // Walk up from this source file to the repo root
        // without hard-coding an absolute path — the test
        // binary is relocatable, but the .swift source file
        // sits at a known depth relative to Package.swift.
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()  // SpooktacularKitTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // <repo root>
        let serverFile = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SpooktacularGuestAgentCore")
            .appendingPathComponent("AgentHTTPServer.swift")

        let source = try String(contentsOf: serverFile, encoding: .utf8)

        // `exit(` inside the accept path is the anti-pattern
        // we're guarding against. Allow the substring in
        // comments — grep by line and ignore those.
        let codeLines = source
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("//")
            }

        let offenders = codeLines.filter { line in
            // `exit(` as a function call — avoid matching
            // `.withunsafe(... , exit: ...)` labels (not
            // currently present, but future-proof).
            line.contains("exit(") && !line.contains("func ")
        }

        #expect(
            offenders.isEmpty,
            "AgentHTTPServer.swift must not call exit() — it runs inside the SwiftUI guest-tools app where a process-wide exit would kill the SPICE clipboard bridge. Offenders: \(offenders)"
        )
    }

    @Test("acceptLoop and listenAll are not typed `-> Never`")
    func acceptLoopIsNotNever() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let repoRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serverFile = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("SpooktacularGuestAgentCore")
            .appendingPathComponent("AgentHTTPServer.swift")

        let source = try String(contentsOf: serverFile, encoding: .utf8)

        // `-> Never` on acceptLoop / listenAll would force
        // the compiler to guarantee the function cannot
        // return normally — which in Swift is expressed via
        // `fatalError()`, `exit()`, or infinite loops. The
        // SwiftUI guest-tools app must be able to recover
        // from a failed listener without process death.
        #expect(
            !source.contains("acceptLoop") || !source.contains("acceptLoop(port: UInt32, channelScope: EndpointScope) -> Never"),
            "acceptLoop must not be typed `-> Never` — callers need a normal return path when vsock isn't available."
        )
        #expect(
            !source.contains("func listenAll") || !source.contains("listenAll(\n")
            || !source.contains(") -> Never"),
            "listenAll must not be typed `-> Never`."
        )
    }
}
