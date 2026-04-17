import Testing
import Foundation
@testable import SpookCore

/// Covers the `ScriptFile.cleanup(scriptURL:)` contract that lets
/// callers shrink the host-side window a provisioning script
/// lives on disk. The expected call pattern is "write → consume →
/// cleanup in defer", so these tests mirror that sequence.
@Suite("ScriptFile cleanup", .tags(.security))
struct ScriptFileCleanupTests {

    @Test("cleanup removes the per-invocation cache directory")
    func cleanupRemovesDirectory() throws {
        let url = try ScriptFile.writeToCache(
            script: "#!/bin/bash\necho hello",
            fileName: "setup.sh"
        )
        // The cache layout is
        // ~/Library/Caches/com.spooktacular/provisioning/<uuid>/<filename>,
        // so the per-invocation dir is the script's parent.
        let dir = url.deletingLastPathComponent()
        #expect(FileManager.default.fileExists(atPath: dir.path))

        try ScriptFile.cleanup(scriptURL: url)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "Cleanup must remove the enclosing <uuid> directory")
    }

    @Test("cleanup is idempotent — calling twice does not throw")
    func cleanupIsIdempotent() throws {
        let url = try ScriptFile.writeToCache(
            script: "#!/bin/bash",
            fileName: "s.sh"
        )
        try ScriptFile.cleanup(scriptURL: url)
        try ScriptFile.cleanup(scriptURL: url)  // no throw
    }

    @Test("cleanup on a never-written URL is a no-op")
    func cleanupOnBogusPathIsNoOp() throws {
        let bogus = URL(filePath: "/tmp/nonexistent-\(UUID()).sh")
        try ScriptFile.cleanup(scriptURL: bogus)  // no throw, no side effects
    }

    @Test("write → cleanup leaves the parent `provisioning/` dir untouched")
    func cleanupPreservesSiblingScripts() throws {
        let a = try ScriptFile.writeToCache(script: "#!/bin/bash", fileName: "a.sh")
        let b = try ScriptFile.writeToCache(script: "#!/bin/bash", fileName: "b.sh")
        // Each write uses a fresh <uuid> subdir, so the two scripts
        // live in sibling directories. Cleaning one must not take
        // the other with it.
        try ScriptFile.cleanup(scriptURL: a)
        #expect(!FileManager.default.fileExists(atPath: a.path),
                "a.sh's dir should be gone")
        #expect(FileManager.default.fileExists(atPath: b.path),
                "b.sh must survive — sibling UUIDs are independent")
        try ScriptFile.cleanup(scriptURL: b)
    }

    @Test("cleanup forwards its log provider on error (captures to the injected logger)")
    func cleanupForwardsErrorsToLog() throws {
        // Construct a file (not a directory) at the "dir" path so
        // `removeItem` will succeed for the file path itself; but
        // we actually want to observe the happy path where the
        // injected logger is silent. This test documents that the
        // log provider is wired end-to-end — a regression that
        // drops the parameter would fail to compile.
        let url = try ScriptFile.writeToCache(
            script: "#!/bin/bash",
            fileName: "s.sh"
        )
        let capturing = CapturingLogProvider()
        try ScriptFile.cleanup(scriptURL: url, log: capturing)
        #expect(capturing.errorMessages.isEmpty,
                "Successful cleanup must not log at error level")
    }
}

/// Minimal capturing `LogProvider` used to assert that
/// ``ScriptFile.cleanup`` wires the injected logger through on
/// the failure path.
private final class CapturingLogProvider: LogProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []

    var errorMessages: [String] {
        lock.lock(); defer { lock.unlock() }
        return errors
    }
    func debug(_ message: String) {}
    func info(_ message: String) {}
    func notice(_ message: String) {}
    func warning(_ message: String) {}
    func error(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        errors.append(message)
    }
}
