import Foundation
import SpookCore
import SpookApplication
import os
@preconcurrency import Virtualization

/// An error thrown when an operation is attempted on a
/// `VirtualMachine` whose underlying `VZVirtualMachine` has
/// been released or was never created.
public struct VirtualMachineInvalidatedError: Error, Sendable, LocalizedError {

    /// A human-readable description of the error.
    public var errorDescription: String? {
        "The virtual machine has been invalidated and cannot perform operations."
    }

    /// Guidance on how to resolve the error.
    public var recoverySuggestion: String? {
        "The VM may have been stopped or deallocated. Reload the VM bundle and try again."
    }
}

/// An error thrown when a lifecycle transition is invalid for
/// the VM's current state.
///
/// For example, calling `start()` on a VM that is already running,
/// or `pause()` on one that is stopped.
public enum VirtualMachineLifecycleError: Error, Sendable, LocalizedError {

    /// The requested state transition is not valid.
    ///
    /// - Parameters:
    ///   - from: The VM's current state.
    ///   - to: The requested target state.
    ///   - reason: A human-readable explanation.
    case invalidTransition(
        from: VirtualMachineState,
        to: VirtualMachineState,
        reason: String
    )

    public var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to, let reason):
            "Cannot transition from \(from.rawValue) to \(to.rawValue): \(reason)"
        }
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
/// - Important: Prefer ``stopGracefully(timeout:)`` over
///   ``stopImmediately()``. Force-stopping the Virtualization
///   framework VM is equivalent to pulling the power cord and can
///   corrupt the guest filesystem. The ``stop(graceful:)`` shim
///   always grants a grace window — see its DocC.
@MainActor
public final class VirtualMachine: NSObject {

    // MARK: - Properties

    /// The bundle this VM was created from.
    public let bundle: VirtualMachineBundle

    /// The underlying Virtualization framework VM.
    ///
    /// Exposed **solely** so a `VZVirtualMachineView` (SwiftUI/AppKit)
    /// can bind its `virtualMachine` property for display. Call
    /// Virtualization APIs directly at your own risk — the lifecycle,
    /// state, and thread-safety contracts live on ``VirtualMachine``
    /// itself, and bypassing them produces subtle concurrency bugs.
    ///
    /// For vsock host-to-guest communication, call
    /// ``makeGuestAgentClient(hostSigner:breakGlassToken:)``
    /// instead of reaching into `vzVM.socketDevices`.
    public private(set) var vzVM: VZVirtualMachine?

    /// The current state of the virtual machine.
    public private(set) var state: VirtualMachineState = .stopped

    /// The last error that caused the VM to stop, if any.
    ///
    /// Set when the ``VZVirtualMachineDelegate`` reports an error
    /// or when a lifecycle method (`start`, `pause`, `resume`) throws.
    /// Reset to `nil` when the VM begins a new lifecycle
    /// (transitioning to ``VirtualMachineState/starting`` or
    /// ``VirtualMachineState/resuming``).
    public private(set) var lastError: Error?

    /// The last network attachment disconnection error, if any.
    ///
    /// Set when the ``VZVirtualMachineDelegate`` reports a network
    /// device disconnection. Callers can observe this to detect
    /// unexpected network failures.
    public private(set) var lastNetworkError: Error?

    /// An asynchronous stream of state changes.
    ///
    /// Subscribe to this stream to observe VM lifecycle events.
    /// The stream yields a new value each time the VM transitions
    /// between states (starting, running, paused, stopped, error).
    public let stateStream: AsyncStream<VirtualMachineState>
    private let stateContinuation: AsyncStream<VirtualMachineState>.Continuation

    /// Default maximum time (in seconds) to wait for a graceful stop
    /// before escalating to a force-stop.
    ///
    /// macOS guests take measurable time to finish shutting down
    /// (LaunchDaemon teardown, filesystem sync, FileVault unmount).
    /// 30s is generous for a runner template with no user sessions;
    /// larger VMs — Xcode caches, Mac Pro simulators — benefit from
    /// a longer timeout passed via the initializer.
    public static let defaultGracefulStopTimeout: Int = 30

    /// The configured maximum time (in seconds) to wait for a graceful
    /// stop before escalating to a force-stop.
    ///
    /// Defaults to ``defaultGracefulStopTimeout``. Override via the
    /// ``init(bundle:gracefulStopTimeout:)`` initializer.
    public let gracefulStopTimeout: Int

    // MARK: - Initialization

    /// Creates a virtual machine from a bundle.
    ///
    /// This initializer builds the `VZVirtualMachineConfiguration`
    /// from the bundle's spec and platform artifacts, validates it,
    /// and creates the underlying `VZVirtualMachine`. The VM is
    /// created in the ``VirtualMachineState/stopped`` state.
    ///
    /// - Parameters:
    ///   - bundle: A VM bundle with a valid disk image and platform
    ///     artifacts (hardware model, machine identifier, auxiliary
    ///     storage).
    ///   - gracefulStopTimeout: Maximum seconds to wait for
    ///     ``stopGracefully(timeout:)`` to observe ``VirtualMachineState/stopped``
    ///     before escalating to a force-stop. Defaults to
    ///     ``defaultGracefulStopTimeout`` (30s). Large VMs with many
    ///     LaunchDaemons or mounted FileVault volumes may benefit from
    ///     60–120s.
    /// - Throws: ``VirtualMachineBundleError`` if platform artifacts are
    ///   missing or invalid, or `VZError` if the configuration
    ///   fails validation.
    public init(
        bundle: VirtualMachineBundle,
        gracefulStopTimeout: Int = VirtualMachine.defaultGracefulStopTimeout
    ) throws {
        self.bundle = bundle
        self.gracefulStopTimeout = gracefulStopTimeout

        let (stream, continuation) = AsyncStream<VirtualMachineState>.makeStream()
        self.stateStream = stream
        self.stateContinuation = continuation

        super.init()

        Log.vm.info("Initializing VM from bundle '\(bundle.url.lastPathComponent, privacy: .public)'")
        let config = VZVirtualMachineConfiguration()
        try VirtualMachineConfiguration.applySpec(bundle.spec, to: config)
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
    //
    // Why `nonisolated(unsafe)`:
    //
    // `VZVirtualMachine`'s async methods (start, stop, pause, resume,
    // saveMachineStateTo, restoreMachineStateFrom) are not annotated
    // as `@MainActor` in the Virtualization framework headers, yet
    // they must be called from the main actor. Because `VirtualMachine`
    // itself is `@MainActor`, we know the `vzVM` reference is only
    // accessed on the main actor. The `nonisolated(unsafe)` local
    // binding satisfies the compiler's sendability check for the
    // `await` suspension point without introducing a data race --
    // the value never escapes the main actor's execution context.

    // MARK: - Guest Agent Factory

    /// Creates a ``GuestAgentClient`` targeting the first vsock device
    /// attached to this VM.
    ///
    /// This is the supported entry point for host-to-guest vsock calls —
    /// callers should not read `vzVM.socketDevices` directly. Returns
    /// `nil` if the VM is not yet created (i.e. `vzVM == nil`) or has
    /// no vsock device in its configuration.
    ///
    /// - Parameters:
    ///   - hostSigner: SEP-bound (or software) P-256 signer that
    ///     attests this host's identity on readonly / runner
    ///     channels. `nil` → no-auth mode (works only when the
    ///     agent is also running without a trust allowlist).
    ///   - breakGlassToken: Bearer credential for port 9472,
    ///     typically a `bgt:`-prefixed ticket.
    public func makeGuestAgentClient(
        hostSigner: (any P256Signer)? = nil,
        breakGlassToken: String? = nil
    ) -> GuestAgentClient? {
        guard let vzVM,
              let socketDevice = vzVM.socketDevices.first as? VZVirtioSocketDevice else {
            return nil
        }
        return GuestAgentClient(
            socketDevice: socketDevice,
            hostSigner: hostSigner,
            breakGlassToken: breakGlassToken
        )
    }

    /// Starts the virtual machine.
    ///
    /// The VM transitions from ``VirtualMachineState/stopped`` to
    /// ``VirtualMachineState/starting``, then to ``VirtualMachineState/running``
    /// once the guest OS begins executing.
    ///
    /// - Throws: An error if the VM cannot be started.
    public func start() async throws {
        guard let virtualMachine = vzVM else { throw VirtualMachineInvalidatedError() }
        guard virtualMachine.canStart else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .starting,
                reason: "VM cannot start in its current state"
            )
        }
        Log.vm.info("Starting VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
        updateState(.starting)
        nonisolated(unsafe) let unsafeVM = virtualMachine
        do {
            try await unsafeVM.start()
        } catch {
            Log.vm.error("Failed to start VM '\(self.bundle.url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            lastError = error
            updateState(.error)
            throw error
        }
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' is running")
        updateState(.running)
    }

    /// The short "panic" timeout used by ``stop(graceful:)`` when the
    /// caller passes `graceful: false` — we still attempt one graceful
    /// shutdown before force-stopping, because force-stop can corrupt
    /// the guest filesystem. If the caller genuinely wants to force-stop
    /// with zero grace period (e.g. the guest is known-dead), call
    /// ``stopImmediately()`` directly.
    ///
    /// See: <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/stop(completionhandler:)>
    public static let forcedStopGraceWindow: Int = 5

    /// Stops the virtual machine gracefully, escalating to a force-stop
    /// after a timeout if the guest ignores the request.
    ///
    /// Sends `VZVirtualMachine.requestStop()` (equivalent to pressing
    /// the power button on real hardware) and waits for the VM to
    /// observe ``VirtualMachineState/stopped``. If the stream does not
    /// yield `.stopped` within `timeout` seconds, escalates to
    /// ``VZVirtualMachine/stop(completionHandler:)`` — analogous to
    /// holding the power button.
    ///
    /// This is the **preferred** shutdown path. It gives the guest a
    /// chance to flush caches, stop LaunchDaemons, and unmount
    /// filesystems — preventing corruption.
    ///
    /// - Parameter timeout: Seconds to wait for graceful shutdown
    ///   before escalating. Defaults to ``gracefulStopTimeout``
    ///   (configured via ``init(bundle:gracefulStopTimeout:)``).
    ///
    /// - Note: macOS guests generally honor `requestStop` via the
    ///   Virtualization framework's synthetic power-button event.
    ///   Older guests (pre-14) may require a prior SSH / vsock
    ///   `shutdown -h now` — see ``GuestAgentClient`` for the vsock
    ///   path.
    ///
    /// - SeeAlso: <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/requeststop()>
    public func stopGracefully(timeout: Int? = nil) async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard vm.canRequestStop else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .stopped,
                reason: "VM cannot request a graceful stop in its current state"
            )
        }

        let effectiveTimeout = timeout ?? gracefulStopTimeout
        Log.vm.info("Requesting graceful stop for '\(self.bundle.url.lastPathComponent, privacy: .public)' (timeout \(effectiveTimeout)s)")
        try vm.requestStop()

        // Wait for the state-change stream to yield `.stopped`, or
        // time out after `effectiveTimeout` seconds. Racing two
        // async paths is cheaper than polling — no main-actor hops,
        // no 60× cache-busting Task.detached awakenings.
        let stream = stateStream
        let stopped = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in stream where state == .stopped {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(effectiveTimeout))
                return false
            }
            defer { group.cancelAll() }
            return await group.next() ?? false
        }

        if !stopped {
            Log.vm.warning("Graceful stop timed out after \(effectiveTimeout)s for '\(self.bundle.url.lastPathComponent, privacy: .public)' — escalating to force-stop")
            try await forceStop(vm: vm, reason: "graceful timeout")
        }
    }

    /// Force-stops the virtual machine **without** attempting a
    /// graceful shutdown first.
    ///
    /// Analogous to pulling the power cord. Use only when the guest
    /// is known to be wedged (kernel panic, vsock unreachable,
    /// `stopGracefully` has already escalated and failed).
    ///
    /// - Warning: Force-stopping may cause filesystem corruption in
    ///   the guest. The guest's APFS journal will replay on next
    ///   boot, but in-flight writes may be lost and FileVault-encrypted
    ///   volumes may require repair. **Prefer ``stopGracefully(timeout:)``.**
    ///
    /// - SeeAlso: <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/stop(completionhandler:)>
    public func stopImmediately() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard vm.canStop else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .stopped,
                reason: "VM cannot be force-stopped in its current state"
            )
        }
        try await forceStop(vm: vm, reason: "caller requested stopImmediately")
    }

    /// Stops the virtual machine.
    ///
    /// - Parameter graceful: If `true`, requests a graceful stop and
    ///   waits up to ``gracefulStopTimeout`` seconds before escalating
    ///   to a force-stop. If `false`, the method still attempts a
    ///   graceful shutdown first — with a short ``forcedStopGraceWindow``
    ///   window — before force-stopping. This protects callers from
    ///   inadvertently corrupting the guest filesystem.
    ///
    ///   To skip the grace window entirely (when the guest is known
    ///   to be wedged), call ``stopImmediately()`` directly.
    ///
    /// - Important: Force-stopping a VM may cause filesystem
    ///   corruption in the guest. Always attempt a graceful
    ///   shutdown first; this method does so automatically.
    ///
    /// - SeeAlso: <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/stop(completionhandler:)>
    public func stop(graceful: Bool = false) async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }

        // If the VM cannot accept a graceful stop request (e.g.
        // it already crashed), fall straight through to the raw
        // `VZVirtualMachine.stop()` path. Otherwise, grant a grace
        // window sized by the caller's intent.
        if !vm.canRequestStop {
            Log.vm.info("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' cannot accept graceful stop — proceeding directly to force-stop")
            try await stopImmediately()
            return
        }

        if graceful {
            try await stopGracefully(timeout: gracefulStopTimeout)
        } else {
            // Even the "force-stop" path grants the guest a short
            // grace window — skipping it risks corruption. Callers
            // who know the guest is wedged should call
            // `stopImmediately()` explicitly.
            try await stopGracefully(timeout: Self.forcedStopGraceWindow)
        }
    }

    /// Issues the raw `VZVirtualMachine.stop()` call and logs the escalation.
    ///
    /// Shared between ``stopGracefully(timeout:)`` (on timeout) and
    /// ``stopImmediately()`` (direct).
    private func forceStop(vm: VZVirtualMachine, reason: String) async throws {
        Log.vm.info("Force-stopping VM '\(self.bundle.url.lastPathComponent, privacy: .public)' (\(reason, privacy: .public))")
        nonisolated(unsafe) let unsafeVM = vm
        try await unsafeVM.stop()
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' stopped")
    }

    /// Pauses the virtual machine.
    ///
    /// The guest's execution is suspended. Memory and device
    /// state are preserved. Resume with ``resume()``.
    public func pause() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard vm.canPause else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .pausing,
                reason: "VM cannot pause in its current state"
            )
        }
        Log.vm.info("Pausing VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
        updateState(.pausing)
        nonisolated(unsafe) let unsafeVM = vm
        do {
            try await unsafeVM.pause()
        } catch {
            Log.vm.error("Failed to pause VM '\(self.bundle.url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            lastError = error
            updateState(.error)
            throw error
        }
        updateState(.paused)
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' paused")
    }

    /// Resumes a paused virtual machine.
    public func resume() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard vm.canResume else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .resuming,
                reason: "VM cannot resume in its current state"
            )
        }
        Log.vm.info("Resuming VM '\(self.bundle.url.lastPathComponent, privacy: .public)'")
        updateState(.resuming)
        nonisolated(unsafe) let unsafeVM = vm
        do {
            try await unsafeVM.resume()
        } catch {
            Log.vm.error("Failed to resume VM '\(self.bundle.url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            lastError = error
            updateState(.error)
            throw error
        }
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
    /// - Throws: An error if the save operation fails.
    ///
    /// > Important: The saved state file is tied to the exact
    /// > disk image state at the time of saving. Modifying the
    /// > disk image after saving invalidates the state file.
    public func saveState(to url: URL) async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard vm.canPause else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .paused,
                reason: "VM must be in a pausable state to save (save requires pausing first)"
            )
        }
        Log.vm.info("Saving VM state to \(url.lastPathComponent, privacy: .public)")
        nonisolated(unsafe) let unsafeVM = vm
        try await unsafeVM.saveMachineStateTo(url: url)
        Log.vm.notice("VM state saved successfully")
    }

    /// Restores the virtual machine from a previously saved state.
    ///
    /// Loads the complete runtime state from the specified file
    /// and resumes VM execution from the exact point it was saved.
    ///
    /// - Parameter url: The file URL of a previously saved state.
    /// - Throws: An error if the state file is invalid or
    ///   incompatible with the current disk image.
    public func restoreState(from url: URL) async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.vm.error("State file not found: \(url.lastPathComponent, privacy: .public)")
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSFilePathErrorKey: url.path,
            ])
        }
        Log.vm.info("Restoring VM state from \(url.lastPathComponent, privacy: .public)")
        nonisolated(unsafe) let unsafeVM = vm
        try await unsafeVM.restoreMachineStateFrom(url: url)
        Log.vm.notice("VM state restored — waiting for delegate state update")
    }

    // MARK: - Private

    private func updateState(_ newState: VirtualMachineState) {
        Log.vm.debug("State transition: \(self.state.rawValue, privacy: .public) → \(newState.rawValue, privacy: .public)")
        if newState == .starting || newState == .resuming {
            lastError = nil
        }
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
        let nsError = error as NSError
        Log.vm.error(
            "VM stopped with error — domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public), description: \(nsError.localizedDescription, privacy: .public)"
        )
        Task { @MainActor [weak self] in
            self?.lastError = error
            self?.updateState(.error)
        }
    }

    /// Called when a network attachment is unexpectedly disconnected.
    nonisolated public func virtualMachine(
        _ virtualMachine: VZVirtualMachine,
        networkDevice: VZNetworkDevice,
        attachmentWasDisconnectedWithError error: Error
    ) {
        let nsError = error as NSError
        Log.vm.warning(
            "Network attachment disconnected — domain: \(nsError.domain, privacy: .public), code: \(nsError.code, privacy: .public), description: \(nsError.localizedDescription, privacy: .public)"
        )
        Task { @MainActor [weak self] in
            self?.lastNetworkError = error
        }
    }
}
