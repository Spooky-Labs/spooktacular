import Testing
import Foundation
@testable import SpooktacularInfrastructureApple
import SpooktacularCore

@Suite("DiskInjector provisioner")
struct DiskInjectorProvisionerTests {
    @Test("installProvisionerDaemon fails fast when not privileged")
    func notPrivileged() throws {
        let bundleDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".vm")
        defer { try? FileManager.default.removeItem(at: bundleDir) }
        // A real bundle skeleton (no disk.img — install never ran), so the only
        // reason installProvisionerDaemon can throw is the privilege guard.
        let bundle = try VirtualMachineBundle.create(
            at: bundleDir,
            spec: VirtualMachineSpecification(),
            displayName: "provtest"
        )
        let src = bundleDir.appendingPathComponent("f")
        try "x".write(to: src, atomically: true, encoding: .utf8)
        // Non-root: preflight() must throw before any disk work — so we see
        // notPrivileged, NOT diskImageNotFound.
        let ops = DirectPrivilegedFileOps(effectiveUID: { 501 })
        #expect(throws: PrivilegedOpsError.notPrivileged) {
            try DiskInjector.installProvisionerDaemon(into: bundle, plist: src, runner: src, privileged: ops)
        }
    }
}
