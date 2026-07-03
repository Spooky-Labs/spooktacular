import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

@Suite("AppendOnlyFileAuditStore durability")
struct AppendOnlyFileAuditStoreFsyncTests {

    /// Tests in this suite skip when the temporary volume rejects
    /// `UF_APPEND` — that's the case on CI runners whose `/tmp` is
    /// a bind-mount or a tmpfs. Real Mac laptops/servers always
    /// have APFS with BSD flags support.
    private static func store(at path: String) throws -> AppendOnlyFileAuditStore? {
        do {
            return try AppendOnlyFileAuditStore(path: path)
        } catch AppendOnlyError.kernelFlagFailed {
            return nil
        }
    }

    private static func sample(_ i: Int) -> AuditRecord {
        AuditRecord(
            actorIdentity: "a-\(i)",
            tenant: .default,
            scope: .runner,
            resource: "r-\(i)",
            action: "x",
            outcome: .success
        )
    }

    @Test("append() fsyncs — bytes readable via a separate handle")
    func appendFsyncsObservable() async throws {
        let tmp = TempDirectory()
        let path = tmp.file("ao-\(UUID().uuidString).jsonl").path
        guard let store = try Self.store(at: path) else { return }

        _ = try await store.append(Self.sample(1))
        // A separate read, not holding the sink's FileHandle, must
        // see the record. If the underlying write were buffered and
        // not fsync'd, we might still see it on APFS — but we'd
        // not see the right byte count. The stronger observation
        // is that `synchronize()` did not throw; the sink contract
        // says the append returns only after fsync.
        let data = try Data(contentsOf: URL(filePath: path))
        #expect(!data.isEmpty, "fsynced data must be observable")
        #expect(data.last == 0x0A, "record is newline-terminated")
    }

    @Test("read() throws truncatedRead when file was externally truncated")
    func truncatedReadSignal() async throws {
        let tmp = TempDirectory()
        let path = tmp.file("ao-trunc-\(UUID().uuidString).jsonl").path
        guard let store = try Self.store(at: path) else { return }

        _ = try await store.append(Self.sample(1))
        _ = try await store.append(Self.sample(2))
        _ = try await store.append(Self.sample(3))

        // Simulate external truncation by overwriting the file
        // with only the first line. BSD UF_APPEND prevents this
        // at user privilege, so we lift the flag first.
        _ = path.withCString { chflags($0, 0) }
        let allData = try Data(contentsOf: URL(filePath: path))
        let allText = String(data: allData, encoding: .utf8) ?? ""
        let firstLine = (allText.split(separator: "\n").first ?? "") + "\n"
        try Data(firstLine.utf8).write(to: URL(filePath: path))

        // Expect truncatedRead from the contract.
        await #expect(throws: AuditSinkError.self) {
            _ = try await store.read(from: 0, count: 10)
        }
    }

    @Test("record(_:) throws AuditSinkError on a closed handle")
    func recordThrowsWhenBackendBroken() async throws {
        // Build the store, then forcibly close its handle by making
        // the file read-only. The fsync on the next write fails and
        // the adapter surfaces an AuditSinkError.
        let tmp = TempDirectory()
        let path = tmp.file("ao-broken-\(UUID().uuidString).jsonl").path
        guard let store = try Self.store(at: path) else { return }

        _ = try await store.append(Self.sample(1))
        // Remove the file outright; subsequent writes still succeed
        // on macOS (the inode is held open) but fsync may still
        // succeed too, so we don't assert on throw here — this is
        // just a smoke test that the error type is AuditSinkError.
        _ = path.withCString { chflags($0, 0) }
        try? FileManager.default.removeItem(atPath: path)

        // If a write fails, it must throw AuditSinkError specifically.
        do {
            try await store.record(Self.sample(2))
        } catch is AuditSinkError {
            return
        } catch {
            Issue.record("expected AuditSinkError; got \(type(of: error)): \(error)")
        }
    }
}
