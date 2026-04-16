import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("PIDFile.terminate", .tags(.infrastructure))
struct PIDFileTerminateTests {

    @Test("Removes PID file when process doesn't exist", .timeLimit(.minutes(1)))
    func terminateRemovesStalePIDFile() async throws {
        let tmp = TempDirectory()
        let bundleURL = tmp.file("test.vm")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let stalePID: pid_t = 99999999
        try Data("\(stalePID)".utf8).write(
            to: bundleURL.appendingPathComponent(PIDFile.fileName)
        )

        let pidBefore = try #require(PIDFile.read(from: bundleURL), "PID must exist before terminate")
        #expect(pidBefore == stalePID)

        await PIDFile.terminate(bundleURL: bundleURL)

        #expect(PIDFile.read(from: bundleURL) == nil)
    }

    @Test("Is no-op when no PID file exists", .timeLimit(.minutes(1)))
    func terminateNoOpWithoutPIDFile() async {
        let tmp = TempDirectory()
        let bundleURL = tmp.file("test.vm")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        #expect(PIDFile.read(from: bundleURL) == nil)
        await PIDFile.terminate(bundleURL: bundleURL)
        #expect(PIDFile.read(from: bundleURL) == nil)
    }
}
