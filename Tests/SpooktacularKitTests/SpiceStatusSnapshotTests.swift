import Foundation
import Testing
@testable import SpooktacularCore

/// Wire-format tests for ``SpiceStatusSnapshot`` — the DTO
/// exchanged over `GET /api/v1/spice/status` between the
/// guest-tools app and the host's workspace toolbar.
@Suite("SpiceStatusSnapshot")
struct SpiceStatusSnapshotTests {

    @Test("Healthy snapshot encodes without a message field")
    func healthyEncodeIsTight() throws {
        let snap = SpiceStatusSnapshot(state: .connected)
        let json = try JSONEncoder().encode(snap)
        let decoded = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        // `message: nil` should still appear in the JSON
        // (Swift's default Codable behaviour emits `null`),
        // but it must decode cleanly round-trip.
        #expect(decoded?["state"] as? String == "connected")

        let roundTrip = try JSONDecoder().decode(
            SpiceStatusSnapshot.self, from: json
        )
        #expect(roundTrip == snap)
    }

    @Test("Failed snapshot carries the error message round-trip")
    func failedCarriesMessage() throws {
        let snap = SpiceStatusSnapshot(
            state: .failed,
            message: "SPICE serial port read failed — errno 32 (Broken pipe)."
        )
        let json = try JSONEncoder().encode(snap)
        let roundTrip = try JSONDecoder().decode(
            SpiceStatusSnapshot.self, from: json
        )
        #expect(roundTrip.state == .failed)
        #expect(roundTrip.message?.contains("errno 32") == true)
    }

    @Test("State raw values stay stable")
    func stateRawValuesStable() {
        // The host maps these string values to pill colors;
        // changing them silently would break wire compat
        // between a newer guest and an older host.
        #expect(SpiceClipboardState.notStarted.rawValue == "notStarted")
        #expect(SpiceClipboardState.connecting.rawValue == "connecting")
        #expect(SpiceClipboardState.connected.rawValue == "connected")
        #expect(SpiceClipboardState.failed.rawValue == "failed")
    }

    @Test("Unknown state value in JSON is rejected")
    func unknownStateRejected() {
        let payload = Data(#"{"state":"newfield"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                SpiceStatusSnapshot.self, from: payload
            )
        }
    }
}
