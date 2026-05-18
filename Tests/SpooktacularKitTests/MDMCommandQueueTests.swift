import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-4b tests for `MDMCommandQueue` — per-UDID FIFO with
/// in-flight tracking and re-delivery semantics.
@Suite("MDM command queue")
struct MDMCommandQueueTests {

    private let alice = "00008103-AAAA"
    private let bob = "00008103-BBBB"

    private func makeCommand(_ ident: String) -> MDMCommand {
        MDMCommand(
            kind: .removeProfile(payloadIdentifier: ident)
        )
    }

    // MARK: - Basic FIFO

    @Test("dequeueNext returns nil for an empty queue")
    func emptyDequeue() async {
        let q = MDMCommandQueue()
        let next = await q.dequeueNext(forUDID: alice)
        #expect(next == nil)
    }

    @Test("Commands deliver in enqueue order (FIFO)")
    func fifoDelivery() async {
        let q = MDMCommandQueue()
        let a = makeCommand("a")
        let b = makeCommand("b")
        let c = makeCommand("c")
        await q.enqueue(a, forUDID: alice)
        await q.enqueue(b, forUDID: alice)
        await q.enqueue(c, forUDID: alice)

        // First poll → a (becomes in-flight)
        #expect(await q.dequeueNext(forUDID: alice) == a)
        await q.acknowledge(commandUUID: a.commandUUID, forUDID: alice)

        // Second → b
        #expect(await q.dequeueNext(forUDID: alice) == b)
        await q.acknowledge(commandUUID: b.commandUUID, forUDID: alice)

        // Third → c
        #expect(await q.dequeueNext(forUDID: alice) == c)
        await q.acknowledge(commandUUID: c.commandUUID, forUDID: alice)

        // Empty
        #expect(await q.dequeueNext(forUDID: alice) == nil)
    }

    // MARK: - In-flight slot + re-delivery

    @Test("Without ack, the same command re-delivers on the next poll")
    func reDeliveryWithoutAck() async {
        let q = MDMCommandQueue()
        let a = makeCommand("a")
        let b = makeCommand("b")
        await q.enqueue(a, forUDID: alice)
        await q.enqueue(b, forUDID: alice)

        #expect(await q.dequeueNext(forUDID: alice) == a)
        // No ack — second poll returns the SAME command, not b
        #expect(await q.dequeueNext(forUDID: alice) == a)
        #expect(await q.dequeueNext(forUDID: alice) == a)

        // After ack we advance to b
        await q.acknowledge(commandUUID: a.commandUUID, forUDID: alice)
        #expect(await q.dequeueNext(forUDID: alice) == b)
    }

    @Test("Acknowledge with the wrong UUID leaves in-flight intact")
    func wrongUUIDAck() async {
        let q = MDMCommandQueue()
        let a = makeCommand("a")
        await q.enqueue(a, forUDID: alice)
        _ = await q.dequeueNext(forUDID: alice)

        let bogus = UUID()
        await q.acknowledge(commandUUID: bogus, forUDID: alice)

        // Still in-flight with the original
        let inFlight = await q.inFlight(forUDID: alice)
        #expect(inFlight?.commandUUID == a.commandUUID)
    }

    @Test("markFailed clears the slot identically to acknowledge (queue advances)")
    func markFailedAdvances() async {
        let q = MDMCommandQueue()
        let a = makeCommand("a")
        let b = makeCommand("b")
        await q.enqueue(a, forUDID: alice)
        await q.enqueue(b, forUDID: alice)

        #expect(await q.dequeueNext(forUDID: alice) == a)
        await q.markFailed(commandUUID: a.commandUUID, forUDID: alice)
        #expect(await q.dequeueNext(forUDID: alice) == b)
    }

    // MARK: - Per-device isolation

    @Test("Per-UDID queues are isolated from each other")
    func perDeviceIsolation() async {
        let q = MDMCommandQueue()
        let alpha = makeCommand("alpha")
        let beta = makeCommand("beta")
        await q.enqueue(alpha, forUDID: alice)
        await q.enqueue(beta, forUDID: bob)

        // Alice's first poll → alpha
        #expect(await q.dequeueNext(forUDID: alice) == alpha)

        // Bob's first poll → beta (Alice's in-flight doesn't affect Bob)
        #expect(await q.dequeueNext(forUDID: bob) == beta)
    }

    // MARK: - removeAll on CheckOut

    @Test("removeAll wipes pending + in-flight for the device")
    func removeAllWipesEverything() async {
        let q = MDMCommandQueue()
        let a = makeCommand("a")
        let b = makeCommand("b")
        await q.enqueue(a, forUDID: alice)
        await q.enqueue(b, forUDID: alice)
        _ = await q.dequeueNext(forUDID: alice)  // a → in-flight

        await q.removeAll(forUDID: alice)
        #expect(await q.dequeueNext(forUDID: alice) == nil)
        #expect(await q.inFlight(forUDID: alice) == nil)
        #expect(await q.pending(forUDID: alice) == [])
    }

    @Test("removeAll on one device leaves others untouched")
    func removeAllScoped() async {
        let q = MDMCommandQueue()
        let alpha = makeCommand("alpha")
        let beta = makeCommand("beta")
        await q.enqueue(alpha, forUDID: alice)
        await q.enqueue(beta, forUDID: bob)

        await q.removeAll(forUDID: alice)
        #expect(await q.dequeueNext(forUDID: alice) == nil)
        #expect(await q.dequeueNext(forUDID: bob) == beta)
    }

    // MARK: - Counters

    @Test("totalPendingCount sums pending across all devices, excluding in-flight")
    func totalPendingCount() async {
        let q = MDMCommandQueue()
        await q.enqueue(makeCommand("a1"), forUDID: alice)
        await q.enqueue(makeCommand("a2"), forUDID: alice)
        await q.enqueue(makeCommand("b1"), forUDID: bob)

        var n = await q.totalPendingCount
        #expect(n == 3)

        // Dequeue moves a1 to in-flight (out of pending)
        _ = await q.dequeueNext(forUDID: alice)
        n = await q.totalPendingCount
        #expect(n == 2)
    }
}
