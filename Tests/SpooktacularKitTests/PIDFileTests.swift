import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

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

    @Test("isRunning removes stale PID file from disk")
    func isRunningRemovesStalePID() throws {
        let bundleURL = makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL.deletingLastPathComponent()) }

        let pidURL = bundleURL.appendingPathComponent(PIDFile.fileName)
        try Data("99999999".utf8).write(to: pidURL)
        #expect(FileManager.default.fileExists(atPath: pidURL.path))

        _ = PIDFile.isRunning(bundleURL: bundleURL)

        #expect(!FileManager.default.fileExists(atPath: pidURL.path))
    }

    // MARK: - writeAndEnsureCapacity

    @Test("writeAndEnsureCapacity succeeds when under limit")
    func writeAndEnsureCapacitySucceeds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let bundleURL = root.appendingPathComponent("test.vm")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try PIDFile.writeAndEnsureCapacity(bundleURL: bundleURL, vmDirectory: root)

        // PID file should exist.
        let pid = PIDFile.read(from: bundleURL)
        #expect(pid == ProcessInfo.processInfo.processIdentifier)
    }

    @Test("writeAndEnsureCapacity succeeds with one existing VM")
    func capacityWithOneExisting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let myPID = ProcessInfo.processInfo.processIdentifier

        // 1 existing "running" VM.
        let existingURL = root.appendingPathComponent("vm1.vm")
        try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
        try Data("\(myPID)".utf8).write(
            to: existingURL.appendingPathComponent(PIDFile.fileName)
        )

        // Our new VM should succeed (1 existing + 1 new = 2, at limit but not over).
        let bundleURL = root.appendingPathComponent("vm2.vm")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        #expect(throws: Never.self) {
            try PIDFile.writeAndEnsureCapacity(bundleURL: bundleURL, vmDirectory: root)
        }

        // PID file should exist after success.
        let pid = PIDFile.read(from: bundleURL)
        #expect(pid == myPID)
    }

    @Test("writeAndEnsureCapacity removes PID and throws when over limit")
    func writeAndEnsureCapacityOverLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let myPID = ProcessInfo.processInfo.processIdentifier

        // Create 2 existing "running" VMs (at the limit).
        for name in ["vm1", "vm2"] {
            let url = root.appendingPathComponent("\(name).vm")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("\(myPID)".utf8).write(
                to: url.appendingPathComponent(PIDFile.fileName)
            )
        }

        // The third VM should fail.
        let bundleURL = root.appendingPathComponent("vm3.vm")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        #expect(throws: CapacityError.self) {
            try PIDFile.writeAndEnsureCapacity(bundleURL: bundleURL, vmDirectory: root)
        }

        // PID file should have been cleaned up.
        #expect(PIDFile.read(from: bundleURL) == nil)
    }

}
