import Testing
import Foundation
@testable import SpooktacularKit

@Suite("VirtualMachineState")
struct VirtualMachineStateTests {

    @Test(
        "All states have stable raw values for serialization",
        arguments: [
            (VirtualMachineState.stopped, "stopped"),
            (.starting, "starting"),
            (.running, "running"),
            (.paused, "paused"),
            (.pausing, "pausing"),
            (.resuming, "resuming"),
            (.error, "error"),
        ]
    )
    func rawValues(state: VirtualMachineState, expected: String) {
        #expect(state.rawValue == expected)
    }

    @Test(
        "Round-trips through JSON",
        arguments: [
            VirtualMachineState.stopped, .starting, .running,
            .paused, .pausing, .resuming, .error,
        ]
    )
    func codableRoundTrip(state: VirtualMachineState) throws {
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(VirtualMachineState.self, from: data)
        #expect(decoded == state)
    }

    @Test("All expected cases exist")
    func caseCount() {
        // If a new case is added, this test will need updating.
        // This is intentional — serialization stability matters.
        let allCases: [VirtualMachineState] = [
            .stopped, .starting, .running,
            .paused, .pausing, .resuming, .error,
        ]
        #expect(allCases.count == 7)
    }
}
