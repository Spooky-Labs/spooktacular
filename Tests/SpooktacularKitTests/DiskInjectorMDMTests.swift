import Foundation
import Testing
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularCore

/// Phase-6 tests for `DiskInjector.injectMDMEnrollment(bootstrap:into:)`.
/// The unit under test is a thin wrapper over the existing
/// `inject(scriptBytes:into:)` path; we verify the bridge by
/// inspecting what lands in the bundle's `provision/`
/// directory.
@Suite("DiskInjector — MDM enrollment injection")
struct DiskInjectorMDMTests {

    private func makeProfile(host: String = "host.local", port: Int = 8443) -> MDMEnrollmentProfile {
        MDMEnrollmentProfile.random(
            vmID: UUID(),
            serverURL: URL(string: "https://\(host):\(port)/mdm/server")!,
            checkInURL: URL(string: "https://\(host):\(port)/mdm/checkin")!
        )
    }

    private func makeBundle(in tmp: TempDirectory) throws -> VirtualMachineBundle {
        try VirtualMachineBundle.create(
            at: tmp.url.appendingPathComponent("\(UUID().uuidString).vm"),
            spec: VirtualMachineSpecification(),
            displayName: "test"
        )
    }

    // MARK: - Round-trip

    @Test("injectMDMEnrollment writes first-boot.sh containing the bootstrap script")
    func injectMDMEnrollmentWritesScript() throws {
        let tmp = TempDirectory()
        let bundle = try makeBundle(in: tmp)
        let bootstrap = MDMEnrollmentBootstrap(profile: makeProfile())

        try DiskInjector.injectMDMEnrollment(bootstrap: bootstrap, into: bundle)

        // The script lands at the bundle's provisionScriptURL
        let path = bundle.provisionScriptURL.path
        #expect(FileManager.default.fileExists(atPath: path))
        let bytes = try Data(contentsOf: bundle.provisionScriptURL)
        let script = try #require(String(data: bytes, encoding: .utf8))
        #expect(script.contains("/usr/bin/profiles install -path"))
        #expect(script.contains(MDMEnrollmentBootstrap.installedProfilePath))
    }

    @Test("Server URL embedded in profile flows through to first-boot.sh")
    func serverURLFlowsThrough() throws {
        let tmp = TempDirectory()
        let bundle = try makeBundle(in: tmp)
        let bootstrap = MDMEnrollmentBootstrap(profile: makeProfile(host: "embedded-mdm.example", port: 9443))

        try DiskInjector.injectMDMEnrollment(bootstrap: bootstrap, into: bundle)

        let bytes = try Data(contentsOf: bundle.provisionScriptURL)
        let script = try #require(String(data: bytes, encoding: .utf8))
        #expect(script.contains("https://embedded-mdm.example:9443/mdm/server"))
        #expect(script.contains("https://embedded-mdm.example:9443/mdm/checkin"))
    }

    @Test("Re-injection replaces a previous first-boot.sh atomically")
    func reInjectionReplaces() throws {
        let tmp = TempDirectory()
        let bundle = try makeBundle(in: tmp)

        let first = MDMEnrollmentBootstrap(profile: makeProfile(host: "first.example"))
        try DiskInjector.injectMDMEnrollment(bootstrap: first, into: bundle)
        let firstBytes = try Data(contentsOf: bundle.provisionScriptURL)
        #expect(String(data: firstBytes, encoding: .utf8)?.contains("first.example") == true)

        let second = MDMEnrollmentBootstrap(profile: makeProfile(host: "second.example"))
        try DiskInjector.injectMDMEnrollment(bootstrap: second, into: bundle)
        let secondBytes = try Data(contentsOf: bundle.provisionScriptURL)
        let secondScript = try #require(String(data: secondBytes, encoding: .utf8))
        #expect(secondScript.contains("second.example"))
        #expect(!secondScript.contains("first.example"),
                "Stale first-injection content shouldn't linger after re-injection")
    }

    @Test("inject(scriptBytes:) sets executable bit on the script for Finder visibility")
    func executableBit() throws {
        let tmp = TempDirectory()
        let bundle = try makeBundle(in: tmp)
        let bootstrap = MDMEnrollmentBootstrap(profile: makeProfile())
        try DiskInjector.injectMDMEnrollment(bootstrap: bootstrap, into: bundle)

        let attrs = try FileManager.default.attributesOfItem(
            atPath: bundle.provisionScriptURL.path
        )
        let perms = try #require(attrs[.posixPermissions] as? Int)
        #expect(perms == 0o755)
    }
}
