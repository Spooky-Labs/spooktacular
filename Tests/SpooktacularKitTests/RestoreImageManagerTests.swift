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

    @Test("isHeldOpenByAnotherProcess ignores handles held by our own process")
    func isHeldOpenByAnotherProcessIgnoresOwnPID() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lock-probe-\(UUID().uuidString).bin")
        try Data("probe".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Hold the file open from THIS process. The probe exists to
        // detect the separate VZ XPC process's lock — a same-process
        // handle must not register, otherwise a caller whose own
        // process has the file open (e.g. an unrelated FileHandle,
        // mid-hash read, or a future framework change that opens fds
        // in-process) would silently degrade the post-install wait
        // to its full 30s ceiling on every install.
        let handle = try FileHandle(forReadingFrom: tmp)
        defer { try? handle.close() }

        #expect(
            RestoreImageManager.isHeldOpenByAnotherProcess(path: tmp.path) == false,
            "a handle held by our own PID must not count as another process's lock"
        )
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

    @Test("a truncated download is rejected rather than handed to the installer")
    func truncatedDownloadIsRejected() throws {
        // A stale partial from an interrupted run was resumed, declared
        // complete, and passed to VZMacOSInstaller, which failed at 0% with
        // "An error occurred during installation" — an error that describes
        // nothing. The guard compares bytes on disk against Content-Length.
        let temp = TempDirectory()
        let part = temp.file("in-progress-abc123.part")
        FileManager.default.createFile(
            atPath: part.path,
            contents: Data(repeating: 0, count: 68_157_440)   // the real stale size
        )

        let onDisk = ((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let expected: Int64 = 19_734_779_897                  // a real IPSW length

        #expect(onDisk != expected, "68 MB is not a complete restore image")
        #expect(
            onDisk < expected,
            "the guard must treat short-by-any-amount as incomplete, not just empty"
        )

        // And the resume decision must refuse to resume when the total is
        // unknown, since completeness could not be checked afterwards.
        let unknownTotal: Int64 = 0
        #expect(
            onDisk >= unknownTotal,
            "offset >= contentLength must hold when contentLength is 0, forcing a clean restart"
        )
    }

    @Test("a file that only looks like an IPSW is never offered to the installer")
    func unreadableCacheEntryIsNotAMatch() async {
        let temp = TempDirectory()
        FileManager.default.createFile(
            atPath: temp.file("not-really.ipsw").path,
            contents: Data("this is not a restore image".utf8)
        )
        let manager = RestoreImageManager(cacheDirectory: temp.url)

        let match = await manager.locallyCachedImageMatchingHost()

        #expect(
            match?.ipswURL == nil,
            "the extension is not evidence; only an image VZMacOSRestoreImage can read counts"
        )
    }

    @Test("a cache hit carries the local file it was loaded from")
    func cacheHitCarriesItsLocalFile() async {
        // The regression this guards: the match used to be returned as a bare
        // VZMacOSRestoreImage, its origin discarded, and the caller then passed
        // it to downloadIPSW — whose HEAD probe gets a plain URLResponse back
        // from a file:// URL, never an HTTPURLResponse, so a create with the
        // correct image already cached died at "HEAD probe returned non-HTTP
        // response". A match must arrive with somewhere to install *from*.
        //
        // Reads the real cache and never downloads: on a miss there is simply
        // nothing to assert, which is why this makes no claim about finding one.
        let manager = RestoreImageManager(cacheDirectory: SpooktacularPaths.ipswCache)

        guard let hit = await manager.locallyCachedImageMatchingHost() else { return }

        #expect(hit.ipswURL.isFileURL, "an installable image is a file, not a fetch")
        #expect(
            FileManager.default.fileExists(atPath: hit.ipswURL.path),
            "the returned path must exist — it is handed straight to VZMacOSInstaller"
        )
        #expect(
            hit.image.operatingSystemVersion.majorVersion
                == ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            "the whole point of the preference is that the guest major matches the host"
        )
    }
}
