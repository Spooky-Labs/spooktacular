import Foundation
import Testing
@testable import SpooktacularCore

/// Wire-format tests for the
/// ``SpooktacularCore/GuestEvent/spiceStatus(_:)`` topic.
/// Ensures the event-stream encoding agrees with the snapshot
/// DTO on both sides.
@Suite("GuestEvent.spiceStatus")
struct GuestEventSpiceStatusTests {

    @Test("spiceStatus event round-trips through Codable")
    func roundTrip() throws {
        let event = GuestEvent.spiceStatus(
            SpiceStatusSnapshot(state: .connected)
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(GuestEvent.self, from: data)
        guard case .spiceStatus(let snap) = decoded else {
            Issue.record("Decoded to the wrong case: \(decoded)")
            return
        }
        #expect(snap.state == .connected)
        #expect(snap.message == nil)
    }

    @Test("Wire-level topic discriminator uses the spice.status name")
    func topicNameStable() throws {
        // GhostVM-style `/api/v1/events?topics=` query
        // strings parse against this exact string. Changing
        // it would break the filter surface for any existing
        // shell scripts.
        let event = GuestEvent.spiceStatus(
            SpiceStatusSnapshot(state: .connecting)
        )
        let json = try JSONEncoder().encode(event)
        let obj = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(obj?["topic"] as? String == "spice.status")
    }

    @Test("Topic filter accepts spice.status")
    func filterParsesSpiceStatus() {
        let filter = GuestEventFilter.parse("spice.status")
        #expect(filter.allows(topic: GuestEventFilter.spiceStatusTopic))
        #expect(!filter.allows(topic: GuestEventFilter.statsTopic))
    }

    @Test("Failed snapshot carries the error message through the event envelope")
    func failedRoundTripWithMessage() throws {
        let event = GuestEvent.spiceStatus(
            SpiceStatusSnapshot(
                state: .failed,
                message: "SPICE serial port EPIPE"
            )
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(GuestEvent.self, from: data)
        guard case .spiceStatus(let snap) = decoded else {
            Issue.record("Decoded to the wrong case")
            return
        }
        #expect(snap.state == .failed)
        #expect(snap.message == "SPICE serial port EPIPE")
    }
}
