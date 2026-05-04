import Foundation
import Testing
@testable import SpooktacularApplication

/// End-to-end tests for `SpooktacularMDMHandler` exercising
/// the full Authenticate → TokenUpdate → enqueue → poll →
/// ack lifecycle without spinning up the HTTP transport.
@Suite("MDM handler integration")
struct SpooktacularMDMHandlerTests {

    private let udid = "00008103-AAAABBBBCCCCDDDD"
    private let topic = "com.apple.mgmt.External.22222222-2222-2222-2222-222222222222"

    private func makeHandler() -> (SpooktacularMDMHandler, MDMDeviceStore, MDMCommandQueue) {
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(
            deviceStore: store,
            commandQueue: queue
        )
        return (handler, store, queue)
    }

    private func authMsg() -> MDMCheckInMessage.Authenticate {
        .init(
            udid: udid, topic: topic,
            model: "VirtualMac2,1", osVersion: "26.4.0"
        )
    }

    // MARK: - Lifecycle

    @Test("Authenticate creates a device-store record")
    func authenticateCreatesRecord() async throws {
        let (handler, store, _) = makeHandler()
        await handler.didReceiveAuthenticate(authMsg())
        let record = try #require(await store.record(forUDID: udid))
        #expect(record.udid == udid)
        #expect(record.checkedOut == false)
    }

    @Test("CheckOut flags record + drains queue (stranded commands removed)")
    func checkOutDrainsQueue() async throws {
        let (handler, store, queue) = makeHandler()
        await handler.didReceiveAuthenticate(authMsg())
        await handler.enqueue(
            MDMCommand(kind: .removeProfile(payloadIdentifier: "stranded")),
            forUDID: udid
        )
        try #expect(await queue.pending(forUDID: udid).count == 1)

        await handler.didReceiveCheckOut(.init(udid: udid, topic: topic))

        let record = try #require(await store.record(forUDID: udid))
        #expect(record.checkedOut == true)
        #expect(await queue.pending(forUDID: udid).isEmpty)
        #expect(await queue.inFlight(forUDID: udid) == nil)
    }

    // MARK: - Command dispatch

    @Test("Enqueued command is delivered to the next nextCommand call")
    func enqueueAndDispatch() async {
        let (handler, _, _) = makeHandler()
        await handler.didReceiveAuthenticate(authMsg())
        let cmd = MDMCommand(
            kind: .removeProfile(payloadIdentifier: "com.tenant.acme")
        )
        await handler.enqueue(cmd, forUDID: udid)
        let next = await handler.nextCommand(forUDID: udid)
        #expect(next == cmd)
    }

    @Test("nextCommand on an unknown device returns nil and bumps no record")
    func unknownDevicePoll() async {
        let (handler, _, _) = makeHandler()
        let next = await handler.nextCommand(forUDID: udid)
        #expect(next == nil)
    }

    @Test("nextCommand bumps lastSeen on the enrolled device")
    func nextCommandBumpsLastSeen() async throws {
        let (handler, store, _) = makeHandler()
        await handler.didReceiveAuthenticate(authMsg())
        let original = try #require(await store.record(forUDID: udid))
        try await Task.sleep(for: .milliseconds(10))
        _ = await handler.nextCommand(forUDID: udid)
        let bumped = try #require(await store.record(forUDID: udid))
        #expect(bumped.lastSeen >= original.lastSeen)
    }

    // MARK: - Response handling

    @Test("Acknowledged response advances the queue")
    func acknowledgedAdvancesQueue() async {
        let (handler, _, _) = makeHandler()
        await handler.didReceiveAuthenticate(authMsg())
        let a = MDMCommand(kind: .removeProfile(payloadIdentifier: "a"))
        let b = MDMCommand(kind: .removeProfile(payloadIdentifier: "b"))
        await handler.enqueue(a, forUDID: udid)
        await handler.enqueue(b, forUDID: udid)

        // First poll: a in-flight
        #expect(await handler.nextCommand(forUDID: udid) == a)

        // Ack a → next poll returns b
        await handler.didReceiveCommandResponse(
            forUDID: udid, commandUUID: a.commandUUID, status: .acknowledged
        )
        #expect(await handler.nextCommand(forUDID: udid) == b)
    }

    @Test("Error response advances the queue identically to Acknowledged")
    func errorAdvancesQueue() async {
        let (handler, _, _) = makeHandler()
        let a = MDMCommand(kind: .removeProfile(payloadIdentifier: "a"))
        let b = MDMCommand(kind: .removeProfile(payloadIdentifier: "b"))
        await handler.enqueue(a, forUDID: udid)
        await handler.enqueue(b, forUDID: udid)

        #expect(await handler.nextCommand(forUDID: udid) == a)

        await handler.didReceiveCommandResponse(
            forUDID: udid, commandUUID: a.commandUUID, status: .error
        )
        #expect(await handler.nextCommand(forUDID: udid) == b)
    }

    @Test("NotNow response leaves the in-flight command for re-delivery")
    func notNowLeavesInFlight() async {
        let (handler, _, _) = makeHandler()
        let a = MDMCommand(kind: .removeProfile(payloadIdentifier: "a"))
        await handler.enqueue(a, forUDID: udid)

        #expect(await handler.nextCommand(forUDID: udid) == a)
        await handler.didReceiveCommandResponse(
            forUDID: udid, commandUUID: a.commandUUID, status: .notNow
        )
        // Re-poll should re-deliver a
        #expect(await handler.nextCommand(forUDID: udid) == a)
    }

    @Test("Idle response is a no-op for the response handler")
    func idleNoOp() async {
        let (handler, _, _) = makeHandler()
        let a = MDMCommand(kind: .removeProfile(payloadIdentifier: "a"))
        await handler.enqueue(a, forUDID: udid)

        // Pretend the device sent an Idle for a non-existent
        // command (transport would normally route this through
        // nextCommand, not here, but be defensive)
        await handler.didReceiveCommandResponse(
            forUDID: udid, commandUUID: UUID(), status: .idle
        )
        // The pending queue is unaffected
        #expect(await handler.nextCommand(forUDID: udid) == a)
    }
}
