import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("ProvisionerAssets")
struct ProvisionerAssetsTests {
    @Test("locate returns nil outside an app bundle (unit-test context)")
    func nilOutsideBundle() {
        // In `swift test` there is no app bundle staging the provisioner
        // resources, and no SPOOKTACULAR_PROVISIONER_DIR override.
        #expect(ProvisionerAssets.locate() == nil)
    }

    @Test("locate resolves both files via the override dir when present")
    func viaOverride() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent(ProvisionerAssets.plistFileName), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(ProvisionerAssets.runnerFileName), atomically: true, encoding: .utf8)
        setenv("SPOOKTACULAR_PROVISIONER_DIR", dir.path, 1)
        defer { unsetenv("SPOOKTACULAR_PROVISIONER_DIR") }
        let found = ProvisionerAssets.locate()
        #expect(found?.plist.lastPathComponent == ProvisionerAssets.plistFileName)
        #expect(found?.runner.lastPathComponent == ProvisionerAssets.runnerFileName)
    }
}
