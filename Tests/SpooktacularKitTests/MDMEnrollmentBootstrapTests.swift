import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-6 tests for `MDMEnrollmentBootstrap`. Verify the
/// generated first-boot script is well-formed bash that
/// includes the embedded mobileconfig + the `profiles
/// install` invocation.
@Suite("MDM enrollment bootstrap")
struct MDMEnrollmentBootstrapTests {

    private func makeProfile() -> MDMEnrollmentProfile {
        MDMEnrollmentProfile(
            vmID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            payloadUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            mdmPayloadUUID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            serverURL: URL(string: "https://host.local:8443/mdm/server")!,
            checkInURL: URL(string: "https://host.local:8443/mdm/checkin")!,
            signaturePolicy: .unsigned
        )
    }

    private func renderScript() throws -> String {
        let bootstrap = MDMEnrollmentBootstrap(profile: makeProfile())
        let data = try bootstrap.script()
        return try #require(String(data: data, encoding: .utf8))
    }

    // MARK: - Shape

    @Test("Script begins with shebang and uses set -euo pipefail")
    func shebangAndStrictMode() throws {
        let script = try renderScript()
        #expect(script.hasPrefix("#!/bin/bash\n"))
        #expect(script.contains("set -euo pipefail"))
    }

    @Test("Script writes profile to the documented path with root:wheel ownership")
    func writesProfilePath() throws {
        let script = try renderScript()
        #expect(script.contains(MDMEnrollmentBootstrap.installedProfilePath))
        #expect(script.contains("install -d -m 0700 -o root -g wheel"))
        #expect(script.contains("chown root:wheel"))
    }

    @Test("Script invokes `profiles install` with -type system")
    func invokesProfilesInstall() throws {
        let script = try renderScript()
        #expect(script.contains("/usr/bin/profiles install -path"))
        #expect(script.contains("-type system"))
    }

    // MARK: - Embedded profile

    @Test("Embedded profile is the actual `mobileconfig()` rendering of the supplied profile")
    func embedsProfileVerbatim() throws {
        let bootstrap = MDMEnrollmentBootstrap(profile: makeProfile())
        let script = try #require(String(data: try bootstrap.script(), encoding: .utf8))
        let expectedXML = try #require(
            String(data: try bootstrap.profile.mobileconfig(), encoding: .utf8)
        )
        // The full mobileconfig payload appears verbatim
        // between the heredoc markers in the script.
        #expect(script.contains(expectedXML.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    @Test("Heredoc terminator appears at column 0 on its own line, twice (open + close)")
    func heredocTerminatorWellFormed() throws {
        let script = try renderScript()
        // We're checking the BLOCK structure is intact —
        // the open `<<'TERMINATOR'` line and the closing
        // `TERMINATOR` line on its own.
        let lines = script.split(separator: "\n", omittingEmptySubsequences: false)
        let openCount = lines.filter { $0.contains("<<'MDM_ENROLLMENT_PROFILE_EOF'") }.count
        let closeCount = lines.filter { $0 == "MDM_ENROLLMENT_PROFILE_EOF" }.count
        #expect(openCount == 1, "Heredoc should open exactly once")
        #expect(closeCount == 1, "Heredoc should close exactly once on its own line")
    }

    // MARK: - URL embedding

    @Test("Server URL appears in the embedded profile so mdmclient dials the right host")
    func embedsServerURL() throws {
        let script = try renderScript()
        #expect(script.contains("https://host.local:8443/mdm/server"))
        #expect(script.contains("https://host.local:8443/mdm/checkin"))
    }

    // MARK: - Bash syntax

    @Test("Generated script passes `bash -n` syntax check on the host")
    func bashSyntaxClean() throws {
        let script = try renderScript()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-bootstrap-\(UUID()).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-n", tmp.path]
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            Issue.record("bash -n rejected the script: \(msg)")
        }
        #expect(process.terminationStatus == 0)
    }
}
