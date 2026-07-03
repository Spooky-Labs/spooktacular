import Foundation

/// Thread-safe wrapper around `LinuxStatsSampler`.
///
/// The sampler holds a previous-sample cache so it needs
/// serialized access. The dialer pumps from one thread today,
/// but wrapping it here keeps the door open for parallel
/// emitters (e.g., the port scanner on a second cadence)
/// without a race.
final class StatsCoordinator: @unchecked Sendable {
    private var sampler = LinuxStatsSampler()
    private let lock = NSLock()

    func snapshot() -> LinuxStatsSampler.StatsFrame {
        lock.lock(); defer { lock.unlock() }
        return sampler.sample()
    }
}
