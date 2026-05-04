import Foundation
import SpooktacularCore
import SpooktacularApplication
import os

/// Concrete ``SignpostProvider`` using Apple's `OSSignposter`.
///
/// Signpost intervals appear in Instruments.app (the *os_signpost*
/// instrument) and are queryable via `log show --signpost`.
///
/// Because ``SignpostProvider`` passes dynamic `String` names while
/// `OSSignposter` requires `StaticString` for interval names, this
/// implementation uses a fixed interval name (`"lifecycle"`) and
/// attaches the dynamic operation name as signpost metadata.
///
/// ## Thread Safety
///
/// All mutable state (the interval-state map and the ID counter) is
/// protected by an `OSAllocatedUnfairLock`, making the provider safe
/// to use from any thread or Swift concurrency context.
public struct OSSignpostProvider: SignpostProvider {

    // MARK: - Private State

    /// Thread-safe storage for in-flight interval states and the
    /// monotonic ID counter.
    private let state: OSAllocatedUnfairLock<State>

    private let signposter: OSSignposter

    /// Internal mutable state protected by the lock.
    private struct State: Sendable {
        /// Monotonically increasing counter used to generate opaque IDs.
        var nextID: UInt64 = 1
        /// Maps opaque IDs to the `OSSignpostIntervalState` needed to
        /// end each interval.
        var intervals: [UInt64: OSSignpostIntervalState] = [:]
    }

    // MARK: - Initializer

    /// Creates a signpost provider backed by `OSSignposter`.
    ///
    /// - Parameters:
    ///   - subsystem: The subsystem identifier, visible in Instruments
    ///     (default: `"com.spooktacular"`).
    ///   - category: The signpost category (default: `"lifecycle"`).
    public init(
        subsystem: String = "com.spooktacular",
        category: String = "lifecycle"
    ) {
        self.signposter = OSSignposter(subsystem: subsystem, category: category)
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    // MARK: - SignpostProvider

    public func beginInterval(_ name: String) -> UInt64 {
        let signpostID = signposter.makeSignpostID()
        let intervalState = signposter.beginInterval("lifecycle", id: signpostID, "\(name)")
        let opaqueID = state.withLock { s in
            let id = s.nextID
            s.nextID += 1
            s.intervals[id] = intervalState
            return id
        }
        return opaqueID
    }

    public func endInterval(_ name: String, id: UInt64) {
        let intervalState = state.withLock { s in
            s.intervals.removeValue(forKey: id)
        }
        guard let intervalState else { return }
        signposter.endInterval("lifecycle", intervalState, "\(name)")
    }

    public func event(_ name: String) {
        signposter.emitEvent("lifecycle", "\(name)")
    }
}
