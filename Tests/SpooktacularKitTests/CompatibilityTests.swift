import Testing
import Foundation
@testable import SpooktacularKit

@Suite("Compatibility")
struct CompatibilityTests {

    @Test("Host version equal to image version is compatible")
    func equalVersions() {
        let host = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .compatible)
    }

    @Test("Host version newer than image version is compatible")
    func newerHost() {
        let host = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .compatible)
    }

    @Test("Host major version newer than image is compatible")
    func newerHostMajor() {
        let host = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .compatible)
    }

    @Test("Host version older than image by minor version is incompatible")
    func olderHostMinor() {
        let host = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .hostTooOld(
            hostVersion: host,
            imageVersion: image
        ))
    }

    @Test("Host version older than image by major version is incompatible")
    func olderHostMajor() {
        let host = OperatingSystemVersion(majorVersion: 15, minorVersion: 4, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .hostTooOld(
            hostVersion: host,
            imageVersion: image
        ))
    }

    @Test("Patch version difference: host older patch is incompatible")
    func olderHostPatch() {
        let host = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1)

        let result = Compatibility.check(hostVersion: host, imageVersion: image)
        #expect(result == .hostTooOld(
            hostVersion: host,
            imageVersion: image
        ))
    }

    @Test("Compatible result provides no message")
    func compatibleMessage() {
        let result = Compatibility.Result.compatible
        #expect(result.isCompatible)
        #expect(result.errorMessage == nil)
    }

    @Test("Incompatible result provides an actionable error message")
    func incompatibleMessage() {
        let host = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 0)
        let image = OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 1)

        let result = Compatibility.Result.hostTooOld(
            hostVersion: host,
            imageVersion: image
        )
        #expect(!result.isCompatible)

        let message = result.errorMessage
        #expect(message != nil)
        #expect(message!.contains("26.2.0"))
        #expect(message!.contains("26.4.1"))
    }

    @Test("Uses real host version by default")
    func realHostVersion() {
        let host = Compatibility.hostVersion
        #expect(host.majorVersion > 0)
    }
}
