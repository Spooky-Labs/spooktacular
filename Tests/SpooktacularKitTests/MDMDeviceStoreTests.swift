import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-4b tests for `MDMDeviceStore` — the in-memory
/// directory of enrolled devices keyed by UDID.
@Suite("MDM device store")
struct MDMDeviceStoreTests {

    // MARK: - Helpers

    /// Pinned clock so `firstSeen` / `lastSeen` are
    /// deterministic across runs.
    private final class FakeClock: @unchecked Sendable {
        private var current: Date
        init(_ initial: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
            self.current = initial
        }
        func advance(by seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
        }
        func now() -> Date { current }
    }

    private func makeStore() -> (MDMDeviceStore, FakeClock) {
        let clock = FakeClock()
        let store = MDMDeviceStore(now: { clock.now() })
        return (store, clock)
    }

    private let udid = "00008103-001234567890ABCD"
    private let topic = "com.apple.mgmt.External.11111111-1111-1111-1111-111111111111"

    private func authMessage(model: String? = "VirtualMac2,1", os: String? = "26.4.0") -> MDMCheckInMessage.Authenticate {
        .init(udid: udid, topic: topic, model: model, osVersion: os)
    }

    // MARK: - Authenticate path

    @Test("upsertAuthenticate creates a fresh record on first contact")
    func freshAuthenticate() async throws {
        let (store, _) = makeStore()
        await store.upsertAuthenticate(authMessage())
        let record = try #require(await store.record(forUDID: udid))
        #expect(record.udid == udid)
        #expect(record.topic == topic)
        #expect(record.model == "VirtualMac2,1")
        #expect(record.osVersion == "26.4.0")
        #expect(record.checkedOut == false)
        #expect(record.firstSeen == record.lastSeen)
    }

    @Test("Re-authenticate refreshes lastSeen but preserves firstSeen")
    func reAuthenticatePreservesFirstSeen() async throws {
        let (store, clock) = makeStore()
        await store.upsertAuthenticate(authMessage())
        let original = try #require(await store.record(forUDID: udid))
        clock.advance(by: 60)
        await store.upsertAuthenticate(authMessage())
        let refreshed = try #require(await store.record(forUDID: udid))
        #expect(refreshed.firstSeen == original.firstSeen)
        #expect(refreshed.lastSeen > original.lastSeen)
    }

    @Test("Re-authenticate after CheckOut clears the checkedOut flag")
    func reAuthenticateAfterCheckOut() async throws {
        let (store, _) = makeStore()
        await store.upsertAuthenticate(authMessage())
        await store.markCheckedOut(udid)
        var r = try #require(await store.record(forUDID: udid))
        #expect(r.checkedOut == true)
        await store.upsertAuthenticate(authMessage())
        r = try #require(await store.record(forUDID: udid))
        #expect(r.checkedOut == false)
    }

    // MARK: - TokenUpdate path

    @Test("upsertTokenUpdate layers push-token + magic onto an existing record")
    func tokenUpdateLayersOnExisting() async throws {
        let (store, _) = makeStore()
        await store.upsertAuthenticate(authMessage())
        let token = Data([0xDE, 0xAD, 0xBE, 0xEF])
        await store.upsertTokenUpdate(.init(
            udid: udid,
            topic: topic,
            pushToken: token,
            pushMagic: "MAGIC",
            unlockToken: nil
        ))
        let r = try #require(await store.record(forUDID: udid))
        // Authenticate-derived fields preserved
        #expect(r.model == "VirtualMac2,1")
        #expect(r.osVersion == "26.4.0")
        // TokenUpdate fields applied
        #expect(r.pushToken == token)
        #expect(r.pushMagic == "MAGIC")
    }

    @Test("TokenUpdate before Authenticate fabricates a partial record (loose mdmclient ordering)")
    func tokenUpdateBeforeAuthenticate() async throws {
        let (store, _) = makeStore()
        await store.upsertTokenUpdate(.init(
            udid: udid,
            topic: topic,
            pushToken: Data([0x01]),
            pushMagic: nil,
            unlockToken: nil
        ))
        let record = try #require(await store.record(forUDID: udid))
        #expect(record.udid == udid)
        #expect(record.pushToken == Data([0x01]))
        #expect(record.model == nil)
    }

    // MARK: - CheckOut + lastSeen

    @Test("markCheckedOut sets the flag without deleting the record")
    func checkOutMarksFlag() async throws {
        let (store, _) = makeStore()
        await store.upsertAuthenticate(authMessage())
        await store.markCheckedOut(udid)
        let r = try #require(await store.record(forUDID: udid))
        #expect(r.checkedOut == true)
    }

    @Test("touchLastSeen bumps lastSeen without altering other fields")
    func touchLastSeen() async throws {
        let (store, clock) = makeStore()
        await store.upsertAuthenticate(authMessage())
        let original = try #require(await store.record(forUDID: udid))
        clock.advance(by: 30)
        await store.touchLastSeen(udid)
        let bumped = try #require(await store.record(forUDID: udid))
        #expect(bumped.lastSeen > original.lastSeen)
        #expect(bumped.topic == original.topic)
        #expect(bumped.model == original.model)
    }

    // MARK: - allEnrolled

    @Test("allEnrolled hides checked-out records but keeps them queryable by UDID")
    func allEnrolledHidesCheckedOut() async throws {
        let (store, _) = makeStore()
        await store.upsertAuthenticate(authMessage())

        let secondUDID = "00008103-FFFFFFFFFFFFFFFF"
        await store.upsertAuthenticate(.init(
            udid: secondUDID, topic: topic, model: nil, osVersion: nil
        ))
        await store.markCheckedOut(secondUDID)

        let enrolled = await store.allEnrolled()
        #expect(enrolled.map(\.udid) == [udid])

        // Direct lookup still works for the checked-out one
        let checkedOut = try #require(await store.record(forUDID: secondUDID))
        #expect(checkedOut.checkedOut == true)
    }

    @Test("allEnrolled is sorted by UDID for deterministic UI")
    func allEnrolledSorted() async {
        let (store, _) = makeStore()
        let alpha = "00008103-AAAAAAAAAAAAAAAA"
        let beta = "00008103-BBBBBBBBBBBBBBBB"
        let gamma = "00008103-CCCCCCCCCCCCCCCC"
        for u in [gamma, alpha, beta] {
            await store.upsertAuthenticate(.init(
                udid: u, topic: topic, model: nil, osVersion: nil
            ))
        }
        let enrolled = await store.allEnrolled()
        #expect(enrolled.map(\.udid) == [alpha, beta, gamma])
    }
}
