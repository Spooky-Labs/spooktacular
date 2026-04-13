import Testing
import Foundation
@testable import SpooktacularKit

@Suite("PIDFile.terminate")
struct PIDFileTerminateTests {

    /// Creates a temporary bundle directory for testing.
    private func makeTempBundle() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.vm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("terminate removes PID file when process doesn't exist")
    func terminateRemovesStalePIDFile() async throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        // Write a PID file with a dead process ID.
        let stalePID: pid_t = 99999999
        try Data("\(stalePID)".utf8).write(
            to: bundleURL.appendingPathComponent(PIDFile.fileName)
        )

        // Verify the PID file exists before terminate.
        #expect(PIDFile.read(from: bundleURL) == stalePID)

        await PIDFile.terminate(bundleURL: bundleURL)

        // PID file should be removed.
        #expect(PIDFile.read(from: bundleURL) == nil)
    }

    @Test("terminate is no-op when no PID file exists")
    func terminateNoOpWithoutPIDFile() async {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        // No PID file exists.
        #expect(PIDFile.read(from: bundleURL) == nil)

        // Should not crash or throw.
        await PIDFile.terminate(bundleURL: bundleURL)

        // Still no PID file.
        #expect(PIDFile.read(from: bundleURL) == nil)
    }

    @Test("terminate cleans up after grace period for non-existent process")
    func terminateGracePeriod() async throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        // Write a PID for a dead process.
        try Data("99999999".utf8).write(
            to: bundleURL.appendingPathComponent(PIDFile.fileName)
        )

        // With a short grace period, should still clean up quickly.
        await PIDFile.terminate(bundleURL: bundleURL, gracePeriod: 1)

        #expect(PIDFile.read(from: bundleURL) == nil)
    }
}
