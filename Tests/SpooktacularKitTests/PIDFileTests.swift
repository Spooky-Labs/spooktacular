import Testing
import Foundation
@testable import SpooktacularKit

@Suite("PIDFile")
struct PIDFileTests {

    /// Creates a temporary bundle directory for testing.
    private func makeTempBundle() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("test.vm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Write and Read

    @Test("Writes current PID and reads it back")
    func writeAndRead() throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        try PIDFile.write(to: bundleURL)

        let pid = PIDFile.read(from: bundleURL)
        let expected = ProcessInfo.processInfo.processIdentifier
        #expect(pid == expected)
    }

    @Test("Read returns nil when no PID file exists")
    func readNonexistent() {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let pid = PIDFile.read(from: bundleURL)
        #expect(pid == nil)
    }

    @Test("Read returns nil for malformed PID file")
    func readMalformed() throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        try Data("not-a-number".utf8).write(
            to: bundleURL.appendingPathComponent(PIDFile.fileName)
        )

        let pid = PIDFile.read(from: bundleURL)
        #expect(pid == nil)
    }

    // MARK: - Remove

    @Test("Remove deletes the PID file")
    func removeDeletesFile() throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        try PIDFile.write(to: bundleURL)
        #expect(PIDFile.read(from: bundleURL) != nil)

        PIDFile.remove(from: bundleURL)
        #expect(PIDFile.read(from: bundleURL) == nil)
    }

    @Test("Remove succeeds silently when no PID file exists")
    func removeNonexistent() {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        // Should not throw or crash.
        PIDFile.remove(from: bundleURL)
    }

    // MARK: - Process Alive Check

    @Test("Current process is alive")
    func currentProcessAlive() {
        let myPID = ProcessInfo.processInfo.processIdentifier
        #expect(PIDFile.isProcessAlive(myPID))
    }

    @Test("Non-existent PID is not alive")
    func nonexistentProcessNotAlive() {
        // PID 99999999 is extremely unlikely to exist.
        #expect(!PIDFile.isProcessAlive(99999999))
    }

    // MARK: - isRunning

    @Test("isRunning returns true when PID file points to a live process")
    func isRunningTrue() throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        try PIDFile.write(to: bundleURL) // writes current process PID
        #expect(PIDFile.isRunning(bundleURL: bundleURL))
    }

    @Test("isRunning returns false when no PID file exists")
    func isRunningNoPIDFile() {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        #expect(!PIDFile.isRunning(bundleURL: bundleURL))
    }

    @Test("isRunning returns false for stale PID file")
    func isRunningStale() throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        try Data("99999999".utf8).write(
            to: bundleURL.appendingPathComponent(PIDFile.fileName)
        )
        #expect(!PIDFile.isRunning(bundleURL: bundleURL))
    }

    // MARK: - File Name

    @Test("PID file name is 'pid'")
    func fileName() {
        #expect(PIDFile.fileName == "pid")
    }
}
