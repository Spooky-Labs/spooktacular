import Testing

// MARK: - VM Lifecycle Integration Tests

/// Integration test stubs for full VM lifecycle operations.
///
/// These tests require Apple Silicon hardware with the Virtualization
/// framework entitlement. They are disabled by default and serve as
/// documentation of the integration scenarios that must be validated
/// on real hardware.
@Suite("VM Lifecycle Integration", .disabled("Requires Apple Silicon with VZ entitlement"))
struct VMLifecycleIntegrationTests {

    @Test("Create VM from IPSW")
    func createFromIPSW() { }

    @Test("Clone VM with new MachineIdentifier")
    func cloneVM() { }

    @Test("Start and stop VM lifecycle")
    func startAndStop() { }

    @Test("Capacity limit prevents 3rd VM")
    func capacityLimit() { }

    @Test("Ephemeral VM deleted on stop")
    func ephemeralRunner() { }

    @Test("Guest agent health check via vsock")
    func agentHealth() { }

    @Test("Guest agent exec returns stdout")
    func agentExec() { }

    @Test("HTTP API clone and start")
    func apiCloneStart() { }

    @Test("Snapshot save and restore")
    func snapshotRoundTrip() { }

    @Test("Delete running VM returns error")
    func deleteRunningFails() { }
}
