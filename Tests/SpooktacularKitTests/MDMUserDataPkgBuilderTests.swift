import Foundation
import Testing
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication

/// Phase 7d — exercises the real `pkgbuild` + `productbuild`
/// pipeline on the test host. Verifies the produced pkg is a
/// well-formed Distribution-style installer pkg by inspecting
/// the output with `pkgutil`.
///
/// Skips silently if `pkgbuild` or `productbuild` aren't on
/// the host (CI sandbox, non-macOS).
@Suite("MDM user-data pkg builder (real pkgbuild)")
struct MDMUserDataPkgBuilderTests {

    private func toolsAvailable() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/pkgbuild") &&
        FileManager.default.fileExists(atPath: "/usr/bin/productbuild")
    }

    @Test("Produces a non-empty Distribution-style pkg whose payload runs the supplied script")
    func realBuildProducesValidPkg() async throws {
        try #require(toolsAvailable(), "pkgbuild/productbuild not on this host")

        let builder = MDMUserDataPkgBuilder()
        let scriptBody = Data("""
        #!/bin/bash
        set -euo pipefail
        echo "user-data ran"
        """.utf8)

        let result = try await builder.buildPkg(
            scriptBody: scriptBody,
            scriptName: "userdata.sh"
        )

        #expect(!result.pkgData.isEmpty, "pkg bytes must be present")
        #expect(result.bundleIdentifier.hasPrefix("com.spookylabs.userdata."))

        // Persist the bytes so we can `pkgutil` them.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-test-\(UUID()).pkg")
        try result.pkgData.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Distribution-style pkgs decompose into a top-level
        // Distribution file + a component pkg. `pkgutil
        // --expand` only succeeds on those; raw component pkgs
        // also expand but without a Distribution sibling.
        let expandedDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-expand-\(UUID())")
        defer { try? FileManager.default.removeItem(at: expandedDir) }

        let expand = Process()
        expand.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        expand.arguments = ["--expand", tmp.path, expandedDir.path]
        expand.standardOutput = FileHandle.nullDevice
        expand.standardError = FileHandle.nullDevice
        try expand.run()
        expand.waitUntilExit()
        #expect(expand.terminationStatus == 0, "pkgutil --expand failed")

        // The Distribution file is what makes Installer.app
        // accept the pkg in its GUI flow — without it, the
        // pkg installs only via `installer -pkg ... -target /`.
        let distFile = expandedDir.appendingPathComponent("Distribution")
        #expect(FileManager.default.fileExists(atPath: distFile.path),
                "Distribution file missing — pkg isn't a productbuild output")
    }

    @Test("buildPkg propagates non-zero exit codes from pkgbuild as processFailed")
    func processFailureSurfaces() async throws {
        // Point the builder at a nonexistent pkgbuild so the
        // Process throws — easier to provoke than a real
        // pkgbuild failure.
        let bogus = MDMUserDataPkgBuilder(pkgbuildPath: "/nonexistent/pkgbuild")
        await #expect(throws: (any Error).self) {
            _ = try await bogus.buildPkg(
                scriptBody: Data("x".utf8),
                scriptName: "x.sh"
            )
        }
    }
}
