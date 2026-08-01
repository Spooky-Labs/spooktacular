import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("ProvisionerAssets")
struct ProvisionerAssetsTests {
    @Test("locate returns nil outside an app bundle (unit-test context)")
    func nilOutsideBundle() {
        // In `swift test` there is no app bundle staging the provisioner
        // resources. The environment is passed explicitly and empty so no
        // override can reach this test — `viaOverride` below used to set one
        // with `setenv`, and under `--parallel` that global leaked into this
        // test and failed it intermittently.
        #expect(ProvisionerAssets.locate(environment: [:]) == nil)
    }

    @Test("locate resolves both files via the override dir when present")
    func viaOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent(ProvisionerAssets.plistFileName), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(ProvisionerAssets.runnerFileName), atomically: true, encoding: .utf8)
        let found = ProvisionerAssets.locate(
            environment: ["SPOOKTACULAR_PROVISIONER_DIR": dir.path]
        )
        #expect(found?.plist.lastPathComponent == ProvisionerAssets.plistFileName)
        #expect(found?.runner.lastPathComponent == ProvisionerAssets.runnerFileName)
    }
}
