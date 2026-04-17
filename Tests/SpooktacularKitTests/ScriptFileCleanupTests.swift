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

        ScriptFile.cleanup(scriptURL: url)

        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "Cleanup must remove the enclosing <uuid> directory")
    }

    @Test("cleanup is idempotent — calling twice does not throw")
    func cleanupIsIdempotent() throws {
        let url = try ScriptFile.writeToCache(
            script: "#!/bin/bash",
            fileName: "s.sh"
        )
        ScriptFile.cleanup(scriptURL: url)
        ScriptFile.cleanup(scriptURL: url)  // no throw
    }

    @Test("cleanup on a never-written URL is a no-op")
    func cleanupOnBogusPathIsNoOp() {
        let bogus = URL(filePath: "/tmp/nonexistent-\(UUID()).sh")
        ScriptFile.cleanup(scriptURL: bogus)  // no throw, no side effects
    }

    @Test("write → cleanup leaves the parent `provisioning/` dir untouched")
    func cleanupPreservesSiblingScripts() throws {
        let a = try ScriptFile.writeToCache(script: "#!/bin/bash", fileName: "a.sh")
        let b = try ScriptFile.writeToCache(script: "#!/bin/bash", fileName: "b.sh")
        // Each write uses a fresh <uuid> subdir, so the two scripts
        // live in sibling directories. Cleaning one must not take
        // the other with it.
        ScriptFile.cleanup(scriptURL: a)
        #expect(!FileManager.default.fileExists(atPath: a.path),
                "a.sh's dir should be gone")
        #expect(FileManager.default.fileExists(atPath: b.path),
                "b.sh must survive — sibling UUIDs are independent")
        ScriptFile.cleanup(scriptURL: b)
    }
}
