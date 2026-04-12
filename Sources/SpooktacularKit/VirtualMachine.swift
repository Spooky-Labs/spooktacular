import Foundation
import os
import Virtualization

/// The lifecycle state of a virtual machine.
///
/// Maps to `VZVirtualMachine.State` but is a ``Sendable`` value
/// type that can be safely shared across actors and published
/// via ``AsyncStream``.
public enum VMState: String, Sendable, Codable {
    /// The VM is not running.
    case stopped
    /// The VM is booting.
    case starting
    /// The VM is running.
    case running
    /// The VM is suspended.
    case paused
    /// The VM is in the process of pausing.
    case pausing
    /// The VM is in the process of resuming.
    case resuming
    /// The VM encountered an error and stopped.
    case error
}

/// A running macOS virtual machine.
///
/// `VirtualMachine` is a thin wrapper around `VZVirtualMachine`
/// that provides an `async`/`await` interface and publishes state
/// changes via ``stateStream``.
///
/// All interactions with the underlying `VZVirtualMachine` happen
/// on the main actor, as required by the Virtualization framework.
///
/// ## Example
///
/// ```swift
/// let vm = try VirtualMachine(bundle: myBundle)
/// try await vm.start()
///
/// for await state in vm.stateStream {
///     print("VM state: \(state)")
/// }
/// ```
///
/// - Important: macOS guests do not respond to
///   `VZVirtualMachine.requestStop()`. Use ``stop(graceful:)``
///   with `graceful: false`, or send a shutdown command via SSH
///   or the vsock channel before stopping.
@MainActor
public final class VirtualMachine: NSObject, Sendable {

    // MARK: - Properties

    /// The bundle this VM was created from.
    public let bundle: VMBundle

    /// The underlying Virtualization framework VM.
    ///
    /// Access only from the main actor.
    public private(set) var vzVM: VZVirtualMachine?

    /// The current state of the virtual machine.
    public private(set) var state: VMState = .stopped

    /// An asynchronous stream of state changes.
    ///
    /// Subscribe to this stream to observe VM lifecycle events.
    /// The stream yields a new value each time the VM transitions
    /// between states (starting, running, paused, stopped, error).
    public let stateStream: AsyncStream<VMState>
    private let stateContinuation: AsyncStream<VMState>.Continuation

    // MARK: - Initialization

    /// Creates a virtual machine from a bundle.
    ///
    /// This initializer builds the `VZVirtualMachineConfiguration`
    /// from the bundle's spec and platform artifacts, validates it,
    /// and creates the underlying `VZVirtualMachine`. The VM is
    /// created in the ``VMState/stopped`` state.
    ///
    /// - Parameter bundle: A VM bundle with a valid disk image
    ///   and platform artifacts (hardware model, machine identifier,
    ///   auxiliary storage).
    /// - Throws: ``VMBundleError`` if platform artifacts are
    ///   missing or invalid, or `VZError` if the configuration
    ///   fails validation.
    public init(bundle: VMBundle) throws {
        self.bundle = bundle

        let (stream, continuation) = AsyncStream<VMState>.makeStream()
        self.stateStream = stream
        self.stateContinuation = continuation

        super.init()

        let config = VZVirtualMachineConfiguration()
        VMConfiguration.applySpec(bundle.spec, to: config)
        try VMConfiguration.applyPlatform(from: bundle, to: config)
        try VMConfiguration.applyStorage(from: bundle, to: config)
        try config.validate()

        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.vzVM = vm
    }

    deinit {
        stateContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts the virtual machine.
    ///
    /// The VM transitions from ``VMState/stopped`` to
    /// ``VMState/starting``, then to ``VMState/running``
    /// once the guest OS begins executing.
    ///
    /// - Throws: An error if the VM cannot be started.
    public func start() async throws {
        guard let vm = vzVM else { return }
        Log.vm.info("Starting VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
        updateState(.starting)
        try await vm.start()
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' is running")
        updateState(.running)
    }

    /// Stops the virtual machine.
    ///
    /// - Parameter graceful: If `true`, sends a stop request
    ///   that the guest can handle gracefully. macOS guests
    ///   typically **do not** respond to this — use SSH or
    ///   vsock to trigger `shutdown -h now` before calling
    ///   this method. If `false`, forcefully terminates the VM.
    ///
    /// - Important: Force-stopping a VM may cause filesystem
    ///   corruption in the guest. Always attempt a graceful
    ///   shutdown first.
    public func stop(graceful: Bool = false) async throws {
        guard let vm = vzVM else { return }

        if graceful {
            try vm.requestStop()
        } else {
            try await vm.stop()
            updateState(.stopped)
        }
    }

    /// Pauses the virtual machine.
    ///
    /// The guest's execution is suspended. Memory and device
    /// state are preserved. Resume with ``resume()``.
    public func pause() async throws {
        guard let vm = vzVM else { return }
        updateState(.pausing)
        try await vm.pause()
        updateState(.paused)
    }

    /// Resumes a paused virtual machine.
    public func resume() async throws {
        guard let vm = vzVM else { return }
        updateState(.resuming)
        try await vm.resume()
        updateState(.running)
    }

    // MARK: - Private

    private func updateState(_ newState: VMState) {
        Log.vm.debug("State transition: \(self.state.rawValue, privacy: .public) → \(newState.rawValue, privacy: .public)")
        state = newState
        stateContinuation.yield(newState)
    }
}

// MARK: - VZVirtualMachineDelegate

extension VirtualMachine: VZVirtualMachineDelegate {

    /// Called when the guest OS has stopped normally.
    nonisolated public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Log.vm.notice("Guest OS stopped normally")
        Task { @MainActor [weak self] in
            self?.updateState(.stopped)
        }
    }

    /// Called when the VM stops due to an error.
    nonisolated public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        didStopWithError error: Error
    ) {
        Log.vm.error("VM stopped with error: \(error.localizedDescription, privacy: .public)")
        Task { @MainActor [weak self] in
            self?.updateState(.error)
        }
    }
}
