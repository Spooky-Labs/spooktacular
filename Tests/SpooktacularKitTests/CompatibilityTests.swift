import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("Compatibility", .tags(.configuration))
struct CompatibilityTests {

    // MARK: - Version Checks (parameterized)

    @Test(
        "Host >= image is compatible",
        arguments: [
            // (host major, host minor, host patch, image major, image minor, image patch)
            (26, 2, 0, 26, 2, 0),  // equal
            (26, 4, 0, 26, 2, 0),  // host newer minor
            (27, 0, 0, 26, 4, 0),  // host newer major
        ]
    )
    func compatible(
        hostMajor: Int, hostMinor: Int, hostPatch: Int,
        imageMajor: Int, imageMinor: Int, imagePatch: Int
    ) {
        let host = OperatingSystemVersion(majorVersion: hostMajor, minorVersion: hostMinor, patchVersion: hostPatch)
        let image = OperatingSystemVersion(majorVersion: imageMajor, minorVersion: imageMinor, patchVersion: imagePatch)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .compatible)
        #expect(result.isCompatible)
        #expect(result.errorMessage == nil)
    }

    @Test(
        "Host < image is incompatible",
        arguments: [
            // (host major, host minor, host patch, image major, image minor, image patch)
            (26, 2, 0, 26, 4, 1),  // host older minor
            (15, 4, 0, 26, 0, 0),  // host older major
            (26, 4, 0, 26, 4, 1),  // host older patch
        ]
    )
    func incompatible(
        hostMajor: Int, hostMinor: Int, hostPatch: Int,
        imageMajor: Int, imageMinor: Int, imagePatch: Int
    ) {
        let host = OperatingSystemVersion(majorVersion: hostMajor, minorVersion: hostMinor, patchVersion: hostPatch)
        let image = OperatingSystemVersion(majorVersion: imageMajor, minorVersion: imageMinor, patchVersion: imagePatch)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .hostTooOld(hostVersion: host, imageVersion: image))
        #expect(!result.isCompatible)
    }

    // MARK: - Error Message

    @Test("Incompatible result provides an actionable error message with version strings")
    func incompatibleMessage() {
        let host = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1)

        let result = Compatibility.Result.hostTooOld(hostVersion: host, imageVersion: image)
        let message = try! #require(result.errorMessage)
        #expect(message.contains("26.2.0"))
        #expect(message.contains("26.4.1"))
    }
}
