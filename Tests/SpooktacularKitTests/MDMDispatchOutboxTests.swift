import Foundation
import Testing
@testable import SpooktacularApplication

/// File-backed IPC tests for `MDMDispatchOutbox`. Each test
/// uses an isolated tempdir so they can run concurrently.
@Suite("MDM dispatch outbox")
struct MDMDispatchOutboxTests {

    private func tmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-outbox-\(UUID())")
    }

    private func makeRequest(
        udid: String = "udid-test",
        scriptBody: String = "#!/bin/bash\necho hi"
    ) -> MDMDispatchOutbox.Request {
        MDMDispatchOutbox.Request(
            udid: udid,
            scriptName: "test.sh",
            scriptBody: Data(scriptBody.utf8)
        )
    }

    // MARK: - Submit + drain round-trip

    @Test("Submit writes a JSON file; drain reads + deletes")
    func submitAndDrain() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = MDMDispatchOutbox(directory: dir)

        let request = makeRequest()
        _ = try await outbox.submit(request)
        #expect(await outbox.pendingCount() == 1)

        var received: [MDMDispatchOutbox.Request] = []
        await outbox.drain { req in
            received.append(req)
            return .delivered
        }
        #expect(received.count == 1)
        #expect(received[0].commandUUID == request.commandUUID)
        #expect(received[0].udid == request.udid)
        #expect(received[0].scriptBody == Data("#!/bin/bash\necho hi".utf8))
        // File deleted after delivery
        #expect(await outbox.pendingCount() == 0)
    }

    @Test("Deferred drain leaves the file in place for next cycle")
    func deferredKeepsFile() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = MDMDispatchOutbox(directory: dir)
        _ = try await outbox.submit(makeRequest())
        await outbox.drain { _ in .deferred }
        // Still there
        #expect(await outbox.pendingCount() == 1)
    }

    @Test("Failed drain renames the file to .failed.json (still excluded from pendingCount)")
    func failedRenamesFile() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = MDMDispatchOutbox(directory: dir)
        let req = try await outbox.submit(makeRequest())
        await outbox.drain { _ in .failed(reason: "test") }
        #expect(await outbox.pendingCount() == 0)
        // .failed.json sibling exists
        let failed = dir.appendingPathComponent("\(req.commandUUID.uuidString).failed.json")
        #expect(FileManager.default.fileExists(atPath: failed.path))
    }

    // MARK: - Cross-process visibility

    @Test("Submit via one outbox handle is visible to another (cross-process IPC shape)")
    func crossHandleVisibility() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Process 1: writes via outbox A
        let outboxA = MDMDispatchOutbox(directory: dir)
        let req = try await outboxA.submit(makeRequest())

        // Process 2: reads via outbox B (different handle, same dir)
        let outboxB = MDMDispatchOutbox(directory: dir)
        var seen: UUID?
        await outboxB.drain { r in
            seen = r.commandUUID
            return .delivered
        }
        #expect(seen == req.commandUUID)
    }

    // MARK: - Malformed input

    @Test("Drain renames invalid JSON to .failed.json instead of looping")
    func malformedJSONRenamed() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bogus = dir.appendingPathComponent("bogus.json")
        try Data("not json".utf8).write(to: bogus)
        let outbox = MDMDispatchOutbox(directory: dir)
        await outbox.drain { _ in .delivered }
        // Renamed
        let failed = dir.appendingPathComponent("bogus.failed.json")
        #expect(FileManager.default.fileExists(atPath: failed.path))
    }

    @Test("Drain on a missing directory is a no-op (no crash)")
    func missingDirectoryNoop() async {
        let dir = tmpDir()  // never created
        let outbox = MDMDispatchOutbox(directory: dir)
        await outbox.drain { _ in .delivered }
        // Doesn't throw, doesn't create the directory either.
        #expect(FileManager.default.fileExists(atPath: dir.path) == false)
    }

    // MARK: - JSON shape

    @Test("Submitted file is pretty-printed JSON with all required keys")
    func jsonShape() async throws {
        let dir = tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outbox = MDMDispatchOutbox(directory: dir)
        let req = try await outbox.submit(makeRequest())
        let url = dir.appendingPathComponent("\(req.commandUUID.uuidString).json")
        let data = try Data(contentsOf: url)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(json["schemaVersion"] as? Int == 1)
        #expect(json["udid"] as? String == "udid-test")
        #expect(json["scriptName"] as? String == "test.sh")
        let body = try #require(json["scriptBodyBase64"] as? String)
        #expect(!body.isEmpty)
        // Pretty-printed
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\n"))
    }
}
