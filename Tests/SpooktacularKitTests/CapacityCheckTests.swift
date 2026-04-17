import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("CapacityCheck", .tags(.infrastructure))
struct CapacityCheckTests {

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

        let spec = VirtualMachineSpecification()
        let configData = try VirtualMachineBundle.encoder.encode(spec)
        try configData.write(to: bundleURL.appendingPathComponent("config.json"))

        let metadata = VirtualMachineMetadata()
        let metadataData = try VirtualMachineBundle.encoder.encode(metadata)
        try metadataData.write(to: bundleURL.appendingPathComponent("metadata.json"))

        if let pid {
            try Data("\(pid)".utf8).write(
                to: bundleURL.appendingPathComponent("pid")
            )
        }
    }

    // MARK: - Limit Constant

    @Test("Maximum concurrent VMs is 2")
    func maxLimit() {
        #expect(CapacityCheck.maxConcurrentVMs == 2)
    }

    // MARK: - Running Count

    @Suite("runningCount", .tags(.infrastructure))
    struct RunningCountTests {

        private var outer: CapacityCheckTests { CapacityCheckTests() }

        @Test("Returns 0 for an empty directory", .timeLimit(.minutes(1)))
        func emptyDirectory() throws {
            let tmp = TempDirectory()
            #expect(CapacityCheck.runningCount(in: tmp.url) == 0)
        }

        @Test("Returns 0 when no VMs have PID files", .timeLimit(.minutes(1)))
        func noPIDFiles() throws {
            let tmp = TempDirectory()
            try outer.createBundle(named: "vm1", in: tmp.url)
            try outer.createBundle(named: "vm2", in: tmp.url)
            #expect(CapacityCheck.runningCount(in: tmp.url) == 0)
        }

        @Test("Returns 0 for stale PID files (dead process)", .timeLimit(.minutes(1)))
        func stalePIDFiles() throws {
            let tmp = TempDirectory()
            try outer.createBundle(named: "vm1", in: tmp.url, withPID: 99999999)
            #expect(CapacityCheck.runningCount(in: tmp.url) == 0)
        }

        @Test("Counts bundle with the current process's PID as running", .timeLimit(.minutes(1)))
        func currentProcessPID() throws {
            let tmp = TempDirectory()
            let myPID = ProcessInfo.processInfo.processIdentifier
            try outer.createBundle(named: "vm1", in: tmp.url, withPID: myPID)
            #expect(CapacityCheck.runningCount(in: tmp.url) == 1)
        }

        @Test("Returns 0 for a nonexistent directory")
        func nonexistentDirectory() {
            let dir = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID())")
            #expect(CapacityCheck.runningCount(in: dir) == 0)
        }
    }

    // MARK: - Running VMs

    @Suite("runningVMs", .tags(.infrastructure))
    struct RunningVMsTests {

        private var outer: CapacityCheckTests { CapacityCheckTests() }

        @Test("Lists running VM names sorted alphabetically", .timeLimit(.minutes(1)))
        func sortedNames() throws {
            let tmp = TempDirectory()
            let myPID = ProcessInfo.processInfo.processIdentifier
            try outer.createBundle(named: "beta", in: tmp.url, withPID: myPID)
            try outer.createBundle(named: "alpha", in: tmp.url, withPID: myPID)
            try outer.createBundle(named: "gamma", in: tmp.url) // no PID

            let names = CapacityCheck.runningVMs(in: tmp.url)
            #expect(names == ["alpha", "beta"])
        }

        @Test("Stale PID files are removed during scan", .timeLimit(.minutes(1)))
        func stalePIDFilesRemoved() throws {
            let tmp = TempDirectory()
            try outer.createBundle(named: "vm1", in: tmp.url, withPID: 99999999)
            let pidURL = tmp.url.appendingPathComponent("vm1.vm")
                .appendingPathComponent(PIDFile.fileName)

            let existed = FileManager.default.fileExists(atPath: pidURL.path)
            try #require(existed, "PID file must exist before scan")

            _ = CapacityCheck.runningVMs(in: tmp.url)
            #expect(!FileManager.default.fileExists(atPath: pidURL.path))
        }
    }

    // MARK: - Ensure Capacity

    @Suite("ensureCapacity", .tags(.infrastructure))
    struct EnsureCapacityTests {

        private var outer: CapacityCheckTests { CapacityCheckTests() }

        @Test("Succeeds when no VMs are running", .timeLimit(.minutes(1)))
        func capacityAvailable() throws {
            let tmp = TempDirectory()
            try outer.createBundle(named: "vm1", in: tmp.url)

            #expect(throws: Never.self) {
                try CapacityCheck.ensureCapacity(in: tmp.url)
            }
        }

        @Test("Succeeds with 1 running VM", .timeLimit(.minutes(1)))
        func capacityWithOne() throws {
            let tmp = TempDirectory()
            let myPID = ProcessInfo.processInfo.processIdentifier
            try outer.createBundle(named: "vm1", in: tmp.url, withPID: myPID)

            #expect(throws: Never.self) {
                try CapacityCheck.ensureCapacity(in: tmp.url)
            }
        }

        @Test("Throws when 2 VMs are running", .timeLimit(.minutes(1)))
        func capacityReached() throws {
            let tmp = TempDirectory()
            let myPID = ProcessInfo.processInfo.processIdentifier
            try outer.createBundle(named: "vm1", in: tmp.url, withPID: myPID)
            try outer.createBundle(named: "vm2", in: tmp.url, withPID: myPID)

            #expect {
                try CapacityCheck.ensureCapacity(in: tmp.url)
            } throws: { error in
                guard let capacityError = error as? CapacityError else { return false }
                if case .limitReached(let running) = capacityError {
                    return running == ["vm1", "vm2"]
                }
                return false
            }
        }
    }

    // MARK: - CapacityError

    @Suite("CapacityError", .tags(.infrastructure))
    struct CapacityErrorTests {

        @Test("Has a descriptive message containing VM count and names")
        func errorMessage() {
            let error = CapacityError.limitReached(running: ["runner-1", "runner-2"])
            let description = error.localizedDescription
            #expect(description.contains("2 concurrent VMs"))
            #expect(description.contains("runner-1"))
            #expect(description.contains("runner-2"))
            let recovery = error.recoverySuggestion ?? ""
            #expect(recovery.contains("Stop a running VM"))
        }

        @Test("Is equatable")
        func errorEquatable() {
            let a = CapacityError.limitReached(running: ["a", "b"])
            let b = CapacityError.limitReached(running: ["a", "b"])
            let c = CapacityError.limitReached(running: ["x"])
            #expect(a == b)
            #expect(a != c)
        }
    }

    // MARK: - Memory Capacity

    @Suite("Memory capacity", .tags(.infrastructure))
    struct MemoryCapacity {

        @Test("ensureMemoryCapacity subtracts overhead before comparing")
        func overheadIsSubtracted() {
            // 16 GiB host, 14 GiB request, 2 GiB overhead:
            // available = 14 GiB, request = 14 GiB → pass.
            let host: UInt64 = 16 * 1024 * 1024 * 1024
            let request: UInt64 = 14 * 1024 * 1024 * 1024
            #expect(throws: Never.self) {
                try CapacityCheck.ensureMemoryCapacity(
                    requestedBytes: request,
                    hostMemoryBytes: host
                )
            }
        }

        @Test("ensureMemoryCapacity rejects a request that exceeds host minus overhead")
        func rejectsRequestAboveLimit() {
            let host: UInt64 = 16 * 1024 * 1024 * 1024
            let request: UInt64 = 15 * 1024 * 1024 * 1024
            do {
                try CapacityCheck.ensureMemoryCapacity(
                    requestedBytes: request,
                    hostMemoryBytes: host
                )
                Issue.record("Expected CapacityError.insufficientMemory")
            } catch let CapacityError.insufficientMemory(requested, available) {
                #expect(requested == request)
                #expect(available == host - CapacityCheck.defaultHostMemoryOverheadBytes)
            } catch {
                Issue.record("Unexpected error type: \(error)")
            }
        }

        @Test("ensureMemoryCapacity never underflows when overhead exceeds host memory")
        func handlesUnderflowSafely() {
            // 1 GiB host, 4 GiB request, default 2 GiB overhead:
            // overhead > host → available clamps to 0 → deny.
            let host: UInt64 = 1 * 1024 * 1024 * 1024
            let request: UInt64 = 4 * 1024 * 1024 * 1024
            #expect(throws: CapacityError.self) {
                try CapacityCheck.ensureMemoryCapacity(
                    requestedBytes: request,
                    hostMemoryBytes: host
                )
            }
        }
    }
}
