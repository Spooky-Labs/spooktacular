import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("VirtualMachineState", .tags(.lifecycle))
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

    @Test("All 7 expected cases exist and serialize correctly")
    func allCasesStable() {
        let allCases: [VirtualMachineState] = [
            .stopped, .starting, .running,
            .paused, .pausing, .resuming, .error,
        ]
        // If a new case is added, this test will need updating.
        // This is intentional -- serialization stability matters.
        let rawValues = Set(allCases.map(\.rawValue))
        #expect(rawValues.count == 7)
        #expect(rawValues == ["stopped", "starting", "running", "paused", "pausing", "resuming", "error"])
    }
}
