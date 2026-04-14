import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("CapacityCheck")
struct CapacityCheckTests {

    /// Creates a temporary directory for a test.
    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    }

    /// Creates a fake VM bundle with an optional PID file.
    private func createBundle(
        named name: String,
        in directory: URL,
        withPID pid: pid_t? = nil
    ) throws {
        let bundleURL = directory.appendingPathComponent("\(name).vm")
        try FileManager.default.createDirectory(
            at: bundleURL,
            withIntermediateDirectories: true
        )

        // Write a minimal config.json and metadata.json so it's a valid bundle dir.
        let spec = VirtualMachineSpecification()
        let configData = try VirtualMachineBundle.encoder.encode(spec)
        try configData.write(to: bundleURL.appendingPathComponent("config.json"))

        let metadata = VirtualMachineMetadata()
        let metadataData = try VirtualMachineBundle.encoder.encode(metadata)
        try metadataData.write(to: bundleURL.appendingPathComponent("metadata.json"))

        if let pid {
            let pidData = Data("\(pid)".utf8)
            try pidData.write(to: bundleURL.appendingPathComponent("pid"))
        }
    }

    // MARK: - Limit Constant

    @Test("Maximum concurrent VMs is 2")
    func maxLimit() {
        #expect(CapacityCheck.maxConcurrentVMs == 2)
    }

    // MARK: - Running Count

    @Test("Returns 0 for an empty directory")
    func emptyDirectory() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(CapacityCheck.runningCount(in: dir) == 0)
    }

    @Test("Returns 0 when no VMs have PID files")
    func noPIDFiles() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try createBundle(named: "vm1", in: dir)
        try createBundle(named: "vm2", in: dir)

        #expect(CapacityCheck.runningCount(in: dir) == 0)
    }

    @Test("Returns 0 for stale PID files (dead process)")
    func stalePIDFiles() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Use PID 99999999 which is almost certainly not running.
        try createBundle(named: "vm1", in: dir, withPID: 99999999)

        #expect(CapacityCheck.runningCount(in: dir) == 0)
    }

    @Test("Stale PID files are removed during runningVMs scan")
    func stalePIDFilesRemoved() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try createBundle(named: "vm1", in: dir, withPID: 99999999)
        let pidURL = dir.appendingPathComponent("vm1.vm")
            .appendingPathComponent(PIDFile.fileName)

        #expect(FileManager.default.fileExists(atPath: pidURL.path))
        _ = CapacityCheck.runningVMs(in: dir)
        #expect(!FileManager.default.fileExists(atPath: pidURL.path))
    }

    @Test("Counts bundle with the current process's PID as running")
    func currentProcessPID() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let myPID = ProcessInfo.processInfo.processIdentifier
        try createBundle(named: "vm1", in: dir, withPID: myPID)

        #expect(CapacityCheck.runningCount(in: dir) == 1)
    }

    @Test("Returns 0 for a nonexistent directory")
    func nonexistentDirectory() {
        let dir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID())")
        #expect(CapacityCheck.runningCount(in: dir) == 0)
    }

    // MARK: - Running VMs

    @Test("Lists running VM names sorted alphabetically")
    func runningVMNames() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let myPID = ProcessInfo.processInfo.processIdentifier
        try createBundle(named: "beta", in: dir, withPID: myPID)
        try createBundle(named: "alpha", in: dir, withPID: myPID)
        try createBundle(named: "gamma", in: dir) // no PID, not running

        let names = CapacityCheck.runningVMs(in: dir)
        #expect(names == ["alpha", "beta"])
    }

    // MARK: - Ensure Capacity

    @Test("ensureCapacity succeeds when no VMs are running")
    func capacityAvailable() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        try createBundle(named: "vm1", in: dir)

        #expect(throws: Never.self) {
            try CapacityCheck.ensureCapacity(in: dir)
        }
    }

    @Test("ensureCapacity succeeds with 1 running VM")
    func capacityWithOne() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let myPID = ProcessInfo.processInfo.processIdentifier
        try createBundle(named: "vm1", in: dir, withPID: myPID)

        #expect(throws: Never.self) {
            try CapacityCheck.ensureCapacity(in: dir)
        }
    }

    @Test("ensureCapacity throws when 2 VMs are running")
    func capacityReached() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let myPID = ProcessInfo.processInfo.processIdentifier
        try createBundle(named: "vm1", in: dir, withPID: myPID)
        try createBundle(named: "vm2", in: dir, withPID: myPID)

        #expect {
            try CapacityCheck.ensureCapacity(in: dir)
        } throws: { error in
            guard let capacityError = error as? CapacityError else { return false }
            if case .limitReached(let running) = capacityError {
                return running == ["vm1", "vm2"]
            }
            return false
        }
    }

    // MARK: - CapacityError

    @Test("CapacityError has a descriptive message")
    func errorMessage() {
        let error = CapacityError.limitReached(running: ["runner-1", "runner-2"])
        let description = error.localizedDescription
        #expect(description.contains("2 concurrent VMs"))
        #expect(description.contains("runner-1"))
        #expect(description.contains("runner-2"))
        let recovery = error.recoverySuggestion ?? ""
        #expect(recovery.contains("Stop a running VM"))
    }

    @Test("CapacityError is equatable")
    func errorEquatable() {
        let a = CapacityError.limitReached(running: ["a", "b"])
        let b = CapacityError.limitReached(running: ["a", "b"])
        let c = CapacityError.limitReached(running: ["x"])
        #expect(a == b)
        #expect(a != c)
    }
}
