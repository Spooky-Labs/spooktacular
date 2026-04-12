import Foundation
import os
import Virtualization

/// An error thrown when an operation is attempted on a
/// `VirtualMachine` whose underlying `VZVirtualMachine` has
/// been released or was never created.
public struct VirtualMachineInvalidatedError: Error, Sendable, LocalizedError {

    /// A human-readable description of the error.
    public var errorDescription: String? {
        "The virtual machine has been invalidated and cannot perform operations."
    }
}

/// The lifecycle state of a virtual machine.
///
/// Maps to `VZVirtualMachine.State` but is a ``Sendable`` value
/// type that can be safely shared across actors and published
/// via ``AsyncStream``.
public enum VirtualMachineState: String, Sendable, Codable {
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
    public let bundle: VirtualMachineBundle

    /// The underlying Virtualization framework VM.
    ///
    /// Access only from the main actor.
    public private(set) var vzVM: VZVirtualMachine?

    /// The current state of the virtual machine.
    public private(set) var state: VirtualMachineState = .stopped

    /// An asynchronous stream of state changes.
    ///
    /// Subscribe to this stream to observe VM lifecycle events.
    /// The stream yields a new value each time the VM transitions
    /// between states (starting, running, paused, stopped, error).
    public let stateStream: AsyncStream<VirtualMachineState>
    private let stateContinuation: AsyncStream<VirtualMachineState>.Continuation

    // MARK: - Initialization

    /// Creates a virtual machine from a bundle.
    ///
    /// This initializer builds the `VZVirtualMachineConfiguration`
    /// from the bundle's spec and platform artifacts, validates it,
    /// and creates the underlying `VZVirtualMachine`. The VM is
    /// created in the ``VirtualMachineState/stopped`` state.
    ///
    /// - Parameter bundle: A VM bundle with a valid disk image
    ///   and platform artifacts (hardware model, machine identifier,
    ///   auxiliary storage).
    /// - Throws: ``VirtualMachineBundleError`` if platform artifacts are
    ///   missing or invalid, or `VZError` if the configuration
    ///   fails validation.
    public init(bundle: VirtualMachineBundle) throws {
        self.bundle = bundle

        let (stream, continuation) = AsyncStream<VirtualMachineState>.makeStream()
        self.stateStream = stream
        self.stateContinuation = continuation

        super.init()

        Log.vm.info("Initializing VM from bundle '\(bundle.url.lastPathComponent, privacy: .public)'")
        let config = VZVirtualMachineConfiguration()
        VirtualMachineConfiguration.applySpec(bundle.spec, to: config)
        try VirtualMachineConfiguration.applyPlatform(from: bundle, to: config)
        try VirtualMachineConfiguration.applyStorage(from: bundle, to: config)
        try config.validate()
        Log.vm.debug("VM configuration validated for '\(bundle.url.lastPathComponent, privacy: .public)'")

        let vm = VZVirtualMachine(configuration: config)
        vm.delegate = self
        self.vzVM = vm
        Log.vm.notice("VM initialized: '\(bundle.url.lastPathComponent, privacy: .public)'")
    }

    deinit {
        stateContinuation.finish()
    }

    // MARK: - Lifecycle

    /// Starts the virtual machine.
    ///
    /// The VM transitions from ``VirtualMachineState/stopped`` to
    /// ``VirtualMachineState/starting``, then to ``VirtualMachineState/running``
    /// once the guest OS begins executing.
    ///
    /// - Throws: An error if the VM cannot be started.
    public func start() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
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
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }

        if graceful {
            Log.vm.info("Requesting graceful stop for '\(self.bundle.url.lastPathComponent, privacy: .public)'")
            try vm.requestStop()
        } else {
            Log.vm.info("Force-stopping VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
            try await vm.stop()
            updateState(.stopped)
            Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' stopped")
        }
    }

    /// Pauses the virtual machine.
    ///
    /// The guest's execution is suspended. Memory and device
    /// state are preserved. Resume with ``resume()``.
    public func pause() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        Log.vm.info("Pausing VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
        updateState(.pausing)
        try await vm.pause()
        updateState(.paused)
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' paused")
    }

    /// Resumes a paused virtual machine.
    public func resume() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        Log.vm.info("Resuming VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
        updateState(.resuming)
        try await vm.resume()
        updateState(.running)
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' resumed")
    }

    // MARK: - Save and Restore State

    /// Saves the virtual machine's state to a file.
    ///
    /// Pauses the VM and writes its complete runtime state
    /// (memory, CPU, device registers) to the specified URL.
    /// The VM remains paused after saving. Call ``resume()``
    /// to continue execution, or ``stop(graceful:)`` to shut
    /// down.
    ///
    /// - Parameter url: The file URL where the state will be
    ///   saved. Typically inside the VM bundle's `SavedStates/`
    ///   directory.
    /// - Throws: An error if save is not supported (requires
    ///   macOS 14+) or if the save operation fails.
    ///
    /// > Important: The saved state file is tied to the exact
    /// > disk image state at the time of saving. Modifying the
    /// > disk image after saving invalidates the state file.
    @available(macOS 14.0, *)
    public func saveState(to url: URL) async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        Log.vm.info("Saving VM state to \(url.lastPathComponent, privacy: .public)")
        try await vm.saveMachineStateTo(url: url)
        Log.vm.notice("VM state saved successfully")
    }

    /// Restores the virtual machine from a previously saved state.
    ///
    /// Loads the complete runtime state from the specified file
    /// and resumes VM execution from the exact point it was saved.
    ///
    /// - Parameter url: The file URL of a previously saved state.
    /// - Throws: An error if restore is not supported (requires
    ///   macOS 14+) or if the state file is invalid or incompatible.
    @available(macOS 14.0, *)
    public func restoreState(from url: URL) async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        Log.vm.info("Restoring VM state from \(url.lastPathComponent, privacy: .public)")
        try await vm.restoreMachineStateFrom(url: url)
        updateState(.running)
        Log.vm.notice("VM state restored — running")
    }

    // MARK: - Private

    private func updateState(_ newState: VirtualMachineState) {
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
