import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("PrivilegedFileOps")
struct PrivilegedFileOpsTests {
    @Test("preflight + ops throw notPrivileged when not root")
    func notRoot() {
        let ops = DirectPrivilegedFileOps(effectiveUID: { 501 })  // pretend non-root
        #expect(throws: PrivilegedOpsError.notPrivileged) { try ops.preflight() }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x")
        #expect(throws: PrivilegedOpsError.notPrivileged) { try ops.makeDirectory(at: tmp) }
    }

    @Test("Direct ops installFile copies + chmods when 'root'")
    func installsFile() throws {
        // effectiveUID stubbed to 0 so the guard passes; chown to root is
        // skipped when the real process isn't root.
        let ops = DirectPrivilegedFileOps(effectiveUID: { 0 }, skipChownWhenNotRoot: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("plist")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        let dst = dir.appendingPathComponent("out.plist")
        try ops.installFile(from: src, to: dst, mode: 0o644)
        #expect(FileManager.default.fileExists(atPath: dst.path))
        let perms = try FileManager.default.attributesOfItem(atPath: dst.path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o644)
    }
}
