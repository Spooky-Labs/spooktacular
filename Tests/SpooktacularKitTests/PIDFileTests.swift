import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("PIDFile", .tags(.infrastructure))
struct PIDFileTests {

    // MARK: - Write and Read

    @Suite("Write and read", .tags(.infrastructure))
    struct WriteReadTests {

        @Test("Writes current PID and reads it back", .timeLimit(.minutes(1)))
        func writeAndRead() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            try PIDFile.write(to: bundleURL)

            let pid = try #require(PIDFile.read(from: bundleURL))
            #expect(pid == ProcessInfo.processInfo.processIdentifier)
        }

        @Test("Read returns nil when no PID file exists", .timeLimit(.minutes(1)))
        func readNonexistent() {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            #expect(PIDFile.read(from: bundleURL) == nil)
        }

        @Test("Read returns nil for malformed PID file", .timeLimit(.minutes(1)))
        func readMalformed() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            try Data("not-a-number".utf8).write(
                to: bundleURL.appendingPathComponent(PIDFile.fileName)
            )
            #expect(PIDFile.read(from: bundleURL) == nil)
        }
    }

    // MARK: - Remove

    @Suite("Remove", .tags(.infrastructure))
    struct RemoveTests {

        @Test("Remove deletes the PID file", .timeLimit(.minutes(1)))
        func removeDeletesFile() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            try PIDFile.write(to: bundleURL)
            try #require(PIDFile.read(from: bundleURL) != nil, "PID file must exist before removal")

            PIDFile.remove(from: bundleURL)
            #expect(PIDFile.read(from: bundleURL) == nil)
        }

        @Test("Remove succeeds silently when no PID file exists", .timeLimit(.minutes(1)))
        func removeNonexistent() {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            PIDFile.remove(from: bundleURL)
        }
    }

    // MARK: - Process Alive Check

    @Suite("isProcessAlive", .tags(.infrastructure))
    struct ProcessAliveTests {

        @Test(
            "Alive check for known PIDs",
            arguments: [
                (ProcessInfo.processInfo.processIdentifier, true),
                (pid_t(99999999), false),
            ]
        )
        func processAlive(pid: pid_t, expectedAlive: Bool) {
            #expect(PIDFile.isProcessAlive(pid) == expectedAlive)
        }
    }

    // MARK: - isRunning

    @Suite("isRunning", .tags(.infrastructure))
    struct IsRunningTests {

        @Test("Returns true when PID file points to a live process", .timeLimit(.minutes(1)))
        func isRunningTrue() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            try PIDFile.write(to: bundleURL)
            #expect(PIDFile.isRunning(bundleURL: bundleURL))
        }

        @Test("Returns false when no PID file exists", .timeLimit(.minutes(1)))
        func isRunningNoPIDFile() {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            #expect(!PIDFile.isRunning(bundleURL: bundleURL))
        }

        @Test("Returns false for stale PID file", .timeLimit(.minutes(1)))
        func isRunningStale() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            try Data("99999999".utf8).write(
                to: bundleURL.appendingPathComponent(PIDFile.fileName)
            )
            #expect(!PIDFile.isRunning(bundleURL: bundleURL))
        }

        @Test("Removes stale PID file from disk", .timeLimit(.minutes(1)))
        func removesStale() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            let pidURL = bundleURL.appendingPathComponent(PIDFile.fileName)
            try Data("99999999".utf8).write(to: pidURL)
            try #require(
                FileManager.default.fileExists(atPath: pidURL.path),
                "PID file must exist before isRunning check"
            )

            _ = PIDFile.isRunning(bundleURL: bundleURL)
            #expect(!FileManager.default.fileExists(atPath: pidURL.path))
        }
    }

    // MARK: - writeAndEnsureCapacity

    @Suite("writeAndEnsureCapacity", .tags(.infrastructure))
    struct WriteAndEnsureCapacityTests {

        @Test("Succeeds when under limit", .timeLimit(.minutes(1)))
        func succeeds() throws {
            let tmp = TempDirectory()
            let bundleURL = tmp.file("test.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            try PIDFile.writeAndEnsureCapacity(bundleURL: bundleURL, vmDirectory: tmp.url)

            let pid = try #require(PIDFile.read(from: bundleURL))
            #expect(pid == ProcessInfo.processInfo.processIdentifier)
        }

        @Test("Succeeds with one existing VM", .timeLimit(.minutes(1)))
        func capacityWithOneExisting() throws {
            let tmp = TempDirectory()
            let myPID = ProcessInfo.processInfo.processIdentifier

            let existingURL = tmp.file("vm1.vm")
            try FileManager.default.createDirectory(at: existingURL, withIntermediateDirectories: true)
            try Data("\(myPID)".utf8).write(
                to: existingURL.appendingPathComponent(PIDFile.fileName)
            )

            let bundleURL = tmp.file("vm2.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            #expect(throws: Never.self) {
                try PIDFile.writeAndEnsureCapacity(bundleURL: bundleURL, vmDirectory: tmp.url)
            }

            let pid = try #require(PIDFile.read(from: bundleURL))
            #expect(pid == myPID)
        }

        @Test("Removes PID and throws when over limit", .timeLimit(.minutes(1)))
        func overLimit() throws {
            let tmp = TempDirectory()
            let myPID = ProcessInfo.processInfo.processIdentifier

            for name in ["vm1", "vm2"] {
                let url = tmp.file("\(name).vm")
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data("\(myPID)".utf8).write(
                    to: url.appendingPathComponent(PIDFile.fileName)
                )
            }

            let bundleURL = tmp.file("vm3.vm")
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

            #expect(throws: CapacityError.self) {
                try PIDFile.writeAndEnsureCapacity(bundleURL: bundleURL, vmDirectory: tmp.url)
            }

            #expect(PIDFile.read(from: bundleURL) == nil)
        }
    }
}
