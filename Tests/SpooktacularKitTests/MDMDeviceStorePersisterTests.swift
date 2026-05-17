import Foundation
import Testing
@testable import SpooktacularApplication

/// Round-trip + cross-process tests for `MDMDeviceStorePersister`.
/// The "cross process" angle is what makes persistence valuable:
/// `spook mdm devices` runs in a different process than `spook
/// mdm serve`, so we verify a flush-from-handler / read-from-CLI
/// shape without two processes.
@Suite("MDM device store persister")
struct MDMDeviceStorePersisterTests {

    private func tmpDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-persister-\(UUID())")
    }

    private func tmpFile() -> URL {
        tmpDir().appendingPathComponent("devices.json")
    }

    private let udid = "00008103-AAAABBBBCCCCDDDD"
    private let topic = "com.apple.mgmt.External.\(UUID().uuidString)"

    // MARK: - Empty state

    @Test("readRecords on a missing file returns []")
    func readRecordsMissing() throws {
        let persister = MDMDeviceStorePersister(fileURL: tmpFile())
        let records = try persister.readRecords()
        #expect(records.isEmpty)
    }

    @Test("load on a missing file returns an empty store")
    func loadMissing() async throws {
        let persister = MDMDeviceStorePersister(fileURL: tmpFile())
        let store = try await persister.load()
        #expect(await store.count == 0)
    }

    // MARK: - Flush + read

    @Test("flush writes a JSON snapshot that readRecords parses back")
    func flushAndReadRecords() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persister = MDMDeviceStorePersister(fileURL: url)

        let store = MDMDeviceStore()
        await store.upsertAuthenticate(.init(
            udid: udid, topic: topic, model: "VirtualMac2,1", osVersion: "26.4.0"
        ))
        try await persister.flush(store)

        let records = try persister.readRecords()
        #expect(records.count == 1)
        let r = try #require(records.first)
        #expect(r.udid == udid)
        #expect(r.topic == topic)
        #expect(r.model == "VirtualMac2,1")
        #expect(r.osVersion == "26.4.0")
        #expect(r.checkedOut == false)
    }

    @Test("Flush + load round-trips a multi-device store with checkedOut state preserved")
    func roundTripMultiDevice() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persister = MDMDeviceStorePersister(fileURL: url)

        let store = MDMDeviceStore()
        await store.upsertAuthenticate(.init(udid: "udid-A", topic: topic, model: nil, osVersion: nil))
        await store.upsertAuthenticate(.init(udid: "udid-B", topic: topic, model: nil, osVersion: nil))
        await store.markCheckedOut("udid-B")
        try await persister.flush(store)

        let reloaded = try await persister.load()
        let aRecord = try #require(await reloaded.record(forUDID: "udid-A"))
        #expect(aRecord.checkedOut == false)
        let bRecord = try #require(await reloaded.record(forUDID: "udid-B"))
        #expect(bRecord.checkedOut == true)

        // allEnrolled should hide B
        let enrolled = await reloaded.allEnrolled()
        #expect(enrolled.map(\.udid) == ["udid-A"])
    }

    // MARK: - Atomic writes

    @Test("Repeated flushes overwrite atomically (writeOptions=.atomic)")
    func atomicOverwrite() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persister = MDMDeviceStorePersister(fileURL: url)

        let store = MDMDeviceStore()
        for i in 0..<5 {
            await store.upsertAuthenticate(.init(
                udid: "udid-\(i)", topic: topic, model: nil, osVersion: nil
            ))
            try await persister.flush(store)
        }
        let final = try persister.readRecords()
        #expect(final.count == 5)
    }

    // MARK: - Handler integration

    @Test("SpooktacularMDMHandler with persister persists Authenticate side effects")
    func handlerSnapshotsOnAuthenticate() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persister = MDMDeviceStorePersister(fileURL: url)
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(
            deviceStore: store,
            commandQueue: queue,
            persister: persister
        )

        await handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: "VM", osVersion: "26.0"
        ))

        // Read from a fresh persister handle (simulating
        // another process) — should see the record.
        let externalReader = MDMDeviceStorePersister(fileURL: url)
        let records = try externalReader.readRecords()
        #expect(records.contains { $0.udid == udid })
    }

    @Test("Handler with persister flushes CheckOut into the snapshot")
    func handlerSnapshotsOnCheckOut() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persister = MDMDeviceStorePersister(fileURL: url)
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(
            deviceStore: store,
            commandQueue: queue,
            persister: persister
        )

        await handler.didReceiveAuthenticate(.init(udid: udid, topic: topic, model: nil, osVersion: nil))
        await handler.didReceiveCheckOut(.init(udid: udid, topic: topic))

        let records = try persister.readRecords()
        let r = try #require(records.first(where: { $0.udid == udid }))
        #expect(r.checkedOut == true)
    }

    // MARK: - JSON shape

    @Test("Output JSON is pretty-printed + sorted keys for reviewability")
    func jsonShape() async throws {
        let url = tmpFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let persister = MDMDeviceStorePersister(fileURL: url)
        let store = MDMDeviceStore()
        await store.upsertAuthenticate(.init(udid: udid, topic: topic, model: "VM", osVersion: "26"))
        try await persister.flush(store)

        let data = try Data(contentsOf: url)
        let text = try #require(String(data: data, encoding: .utf8))
        // Pretty-printed → contains newlines
        #expect(text.contains("\n"))
        // Sorted keys → checkedOut appears before udid alphabetically
        let checkedOutIdx = try #require(text.range(of: "\"checkedOut\""))
        let udidIdx = try #require(text.range(of: "\"udid\""))
        #expect(checkedOutIdx.lowerBound < udidIdx.lowerBound)
    }
}
