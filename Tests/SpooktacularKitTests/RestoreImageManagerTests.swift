import Testing
import Foundation
import CryptoKit
@testable import SpooktacularInfrastructureApple

@Suite("RestoreImageManager", .tags(.infrastructure))
struct RestoreImageManagerTests {

    @Test("DownloadProgress.fraction is finite and clamped")
    func progressFraction() {
        let zero = DownloadProgress(bytesReceived: 0, bytesTotal: 0, resumed: false)
        #expect(zero.fraction == 0.0)

        let half = DownloadProgress(bytesReceived: 50, bytesTotal: 100, resumed: false)
        #expect(half.fraction == 0.5)

        let over = DownloadProgress(bytesReceived: 200, bytesTotal: 100, resumed: true)
        #expect(over.fraction == 1.0, "fraction must clamp at 1.0 when bytesReceived overshoots")

        let resumed = DownloadProgress(bytesReceived: 10, bytesTotal: 100, resumed: true)
        #expect(resumed.resumed == true)
    }

    @Test("sha256 digest matches CryptoKit reference for a known payload")
    func sha256Verification() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        try payload.write(to: tmp)

        let reference = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()

        let manager = RestoreImageManager(cacheDirectory: tmp.deletingLastPathComponent())
        let digest = try manager.sha256(of: tmp)
        #expect(digest == reference)

        #expect(try manager.verifyFileHash(at: tmp, expected: digest) == true)
        #expect(try manager.verifyFileHash(at: tmp, expected: String(repeating: "0", count: 64)) == false)
    }

    @Test("RestoreImageError.downloadFailed carries message")
    func downloadFailedDescription() {
        let err = RestoreImageError.downloadFailed(message: "timeout after 120s")
        #expect(err.localizedDescription.contains("timeout after 120s"))
        #expect(err.recoverySuggestion?.contains("resume") == true)
    }

    // MARK: - isHeldOpenByAnotherProcess
    //
    // Regression coverage for the primitive `install(bundle:from:progress:)`
    // uses to wait out the post-install auxiliary-storage lock (see
    // that method's doc comment for the root-cause writeup: a
    // separate `com.apple.Virtualization.VirtualMachine.xpc` process
    // holds the fd, not anything in our own object graph). Unlike
    // the VZ-framework calls elsewhere in this file, `lsof` has no
    // entitlement or network dependency, so the detection logic
    // itself is fully exercisable here with a real held-open file —
    // no VM required.

    @Test("isHeldOpenByAnotherProcess is false for a path with no holder")
    func isHeldOpenByAnotherProcessNoHolder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-probe-\(UUID().uuidString).bin")
        try Data("probe".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        #expect(RestoreImageManager.isHeldOpenByAnotherProcess(path: tmp.path) == false)
    }

    @Test("isHeldOpenByAnotherProcess is false for a nonexistent path")
    func isHeldOpenByAnotherProcessMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).bin")
        #expect(RestoreImageManager.isHeldOpenByAnotherProcess(path: missing.path) == false)
    }

    @Test("isHeldOpenByAnotherProcess detects an externally-open file and clears once the holder exits")
    func isHeldOpenByAnotherProcessDetectsExternalHolder() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-probe-\(UUID().uuidString).bin")
        try Data("probe".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Hold the file open from a real child process — `tail -f`
        // keeps an fd open on it until killed, mirroring the shape
        // of the real bug: a separate OS process holding the fd,
        // not anything in our own process.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        holder.arguments = ["-f", tmp.path]
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            if holder.isRunning {
                holder.terminate()
                holder.waitUntilExit()
            }
        }

        // Poll for the real condition rather than sleeping a fixed
        // guess — bounded so a stuck process launch can't hang the
        // suite indefinitely.
        var detected = false
        for _ in 0..<20 {
            if RestoreImageManager.isHeldOpenByAnotherProcess(path: tmp.path) {
                detected = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(detected, "expected lsof to report the file held open by the tail process")

        holder.terminate()
        holder.waitUntilExit()

        var released = false
        for _ in 0..<20 {
            if !RestoreImageManager.isHeldOpenByAnotherProcess(path: tmp.path) {
                released = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(released, "expected the lock to clear once the holder process exited")
    }
}
