import Foundation
import SpooktacularCore
import SpooktacularApplication
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

    /// Bridge-availability monitor. Non-nil only when the VM
    /// boots in ``NetworkMode/bridged(interface:)`` — the
    /// monitor watches host Wi-Fi / Ethernet transitions and
    /// cycles the guest's `VZBridgedNetworkDeviceAttachment`
    /// on link-up so the guest re-DHCPs instead of sitting on
    /// a stale lease. See ``BridgeMonitor`` for the rationale.
    private var bridgeMonitor: BridgeMonitor?

    /// NBD attachment delegates kept alive for the VM's
    /// lifetime. `VZNetworkBlockDeviceStorageDeviceAttachment.delegate`
    /// is weak — if we let the monitor deallocate, the
    /// reconnect / error callbacks never fire. The array
    /// lives as long as the VM.
    public private(set) var nbdMonitors: [NBDAttachmentMonitor] = []

    /// Retains an NBD monitor so it lives as long as the VM
    /// does. Called from ``VirtualMachineConfiguration/applyStorage(from:to:)``
    /// right after the delegate is attached to its
    /// attachment. The caller must retain the returned
    /// array entry for its delegate callbacks to fire —
    /// this method does that plumbing.
    public func retainNBDMonitor(_ monitor: NBDAttachmentMonitor) {
        nbdMonitors.append(monitor)
    }

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
        let nbdMonitors = try VirtualMachineConfiguration.applyStorage(
            from: bundle,
            to: config
        )
        // Retain the NBD delegate monitors — the attachment
        // holds them weakly so the lifetime contract is on
        // us. See `NBDAttachmentMonitor` class docs.
        self.nbdMonitors = nbdMonitors

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

    /// Returns the Apple-native event listener for this VM,
    /// creating it on first access.
    ///
    /// The listener uses `VZVirtioSocketListener` —
    /// [Apple's documented pattern](https://developer.apple.com/documentation/virtualization/vzvirtiosocketlistener)
    /// for accepting guest-initiated connections — so the guest
    /// agent pushes events as soon as it boots instead of
    /// waiting for a host probe. Consumers subscribe via
    /// ``AgentEventListener/events()`` to get an
    /// `AsyncThrowingStream<GuestEvent, Error>`.
    ///
    /// Returns `nil` if the VM has no vsock device in its
    /// configuration — the same shape as
    /// ``makeGuestAgentClient(hostSigner:breakGlassToken:)``.
    public func agentEventListener() -> AgentEventListener? {
        guard let vzVM,
              let socketDevice = vzVM.socketDevices.first as? VZVirtioSocketDevice else {
            return nil
        }
        if let cached = cachedEventListener { return cached }
        let listener = AgentEventListener(socketDevice: socketDevice)
        cachedEventListener = listener
        return listener
    }

    /// Per-VM event listener cache. Created lazily on first
    /// `agentEventListener()` call; torn down by
    /// ``shutdownEventListener()`` when the VM stops.
    private var cachedEventListener: AgentEventListener?

    /// Tears down the event listener. Called from the stop
    /// path so the `VZVirtioSocketListener` delegate stops
    /// receiving acceptance callbacks for a departing VM.
    public func shutdownEventListener() {
        cachedEventListener?.stop()
        cachedEventListener = nil
    }

    /// Starts the virtual machine.
    ///
    /// The VM transitions from ``VirtualMachineState/stopped`` to
    /// ``VirtualMachineState/starting``, then to ``VirtualMachineState/running``
    /// once the guest OS begins executing.
    ///
    /// - Parameter startUpFromMacOSRecovery: When `true`, boots
    ///   the guest into macOS Recovery instead of the normal
    ///   boot partition. Passed through to Apple's
    ///   `VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery`.
    ///   Useful for filesystem repair, Startup Security Utility,
    ///   or reinstalling macOS from a snapshot. Defaults to
    ///   `false` — a regular boot.
    /// - Throws: An error if the VM cannot be started.
    ///
    /// Doc: https://developer.apple.com/documentation/virtualization/vzmacosvirtualmachinestartoptions/startupfrommacosrecovery
    public func start(startUpFromMacOSRecovery: Bool = false) async throws {
        guard let virtualMachine = vzVM else { throw VirtualMachineInvalidatedError() }
        guard virtualMachine.canStart else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .starting,
                reason: "VM cannot start in its current state"
            )
        }
        Log.vm.info("Starting VM '\(self.bundle.url.lastPathComponent, privacy: .public)'\(startUpFromMacOSRecovery ? " in Recovery mode" : "")")
        updateState(.starting)
        nonisolated(unsafe) let unsafeVM = virtualMachine
        do {
            if startUpFromMacOSRecovery {
                // Apple's `start(options:)` with
                // `VZMacOSVirtualMachineStartOptions` only exposes
                // a completion-handler variant (no async
                // overload). Wrap it in a continuation so the
                // caller gets the same async ergonomics.
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    unsafeVM.start(options: options) { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } else {
                try await unsafeVM.start()
            }
        } catch {
            Log.vm.error("Failed to start VM '\(self.bundle.url.lastPathComponent, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            lastError = error
            updateState(.error)
            throw error
        }
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' is running")
        updateState(.running)

        // Spin up the bridge recovery monitor if this VM's
        // network spec binds it to a physical interface. On a
        // Wi-Fi / Ethernet link-up the monitor cycles the
        // guest's `VZBridgedNetworkDeviceAttachment` so the
        // guest re-DHCPs instead of sitting on a stale lease
        // — the GhostVM trick, implemented with
        // `NWPathMonitor`. NAT and isolated modes don't need
        // the monitor; the attachment is a VM-internal NAT
        // router, not a physical-network bridge.
        if case .bridged(let interfaceName) = bundle.spec.networkMode,
           let vm = vzVM {
            let monitor = BridgeMonitor(virtualMachine: vm, interface: interfaceName)
            bridgeMonitor = monitor
            monitor.start()
        }
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

        // Tear down the bridge monitor first so we don't
        // cycle the attachment mid-shutdown. Safe to call
        // even when no monitor was installed (NAT / isolated
        // VMs never create one).
        if let monitor = bridgeMonitor {
            monitor.stop()
            bridgeMonitor = nil
        }

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
        // Apple's `saveMachineStateTo(url:)` requires the VM to
        // already be paused — see
        // https://developer.apple.com/documentation/virtualization/vzvirtualmachine/savemachinestateto(url:)
        // The previous `canPause` guard was wrong in both
        // directions: it rejected paused VMs (the one state this
        // API actually accepts) and would have let a running VM
        // through (where save crashes inside VZ).
        guard state == .paused else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .paused,
                reason: "VM must be paused before saving state (call pause() first)"
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

    // MARK: - Suspend / Resume (Apple save-state)

    /// Suspends the VM to disk and shuts it down so the host
    /// process can exit.
    ///
    /// Composes Apple's pause + `saveMachineStateTo(url:)` + stop
    /// sequence into the "close the laptop" gesture the GUI's
    /// Suspend button and the CLI's `spook suspend` verb both
    /// invoke. The saved-state file lives at
    /// ``VirtualMachineBundle/savedStateURL`` — the next
    /// ``start()`` observes it and resumes rather than cold-
    /// booting.
    ///
    /// Semantics, borrowed directly from Apple's
    /// [VZVirtualMachine.saveMachineStateTo(url:)](
    /// https://developer.apple.com/documentation/virtualization/vzvirtualmachine/savemachinestateto(url:))
    /// contract:
    ///
    /// 1. The VM must be pausable (`canPause` is the same gate as
    ///    `pause()`). Throws
    ///    ``VirtualMachineLifecycleError/invalidTransition`` otherwise.
    /// 2. `pause()` is called first; if the VM is already paused
    ///    the step is a no-op and we proceed directly to save.
    /// 3. `saveMachineStateTo` writes the memory/CPU/device
    ///    snapshot to ``VirtualMachineBundle/savedStateURL``
    ///    atomically (Apple writes to a temp file and renames).
    /// 4. `stop(graceful:)` tears down the VM so the host process
    ///    can exit. We use `graceful: false` because the guest is
    ///    already paused — any graceful-shutdown machinery (e.g.,
    ///    `requestStop`) would just time out.
    ///
    /// - Throws: Any error from the underlying Apple calls; the
    ///   saved-state file is removed before rethrowing so a
    ///   half-written snapshot can't later mask a cold-boot
    ///   attempt.
    public func suspend() async throws {
        guard let vm = vzVM else { throw VirtualMachineInvalidatedError() }
        guard vm.canPause || state == .paused else {
            throw VirtualMachineLifecycleError.invalidTransition(
                from: state, to: .paused,
                reason: "VM must be pausable (currently \(state.rawValue)) to suspend"
            )
        }

        let targetURL = bundle.savedStateURL
        Log.vm.info("Suspending VM '\(self.bundle.url.lastPathComponent, privacy: .public)' → \(targetURL.lastPathComponent, privacy: .public)")

        if state != .paused {
            try await pause()
        }

        do {
            try await saveState(to: targetURL)
        } catch {
            // A partial file would masquerade as a valid
            // saved-state on next start and fail restore then,
            // confusing the user. Wipe it here.
            try? FileManager.default.removeItem(at: targetURL)
            throw error
        }

        // Defensive propagation: the `.vzvmsave` file contains a
        // verbatim snapshot of guest RAM and device state — the
        // most sensitive output this VM produces. New files DO
        // inherit the parent directory's Data-Protection class on
        // APFS, but inheritance is known to drift across atomic
        // renames and APFS snapshot boundaries (documented in
        // docs/DATA_AT_REST.md). A one-shot `propagate` here
        // forces the save-file into the same class as the rest of
        // the bundle (CUFUA on portable Macs) so the at-rest
        // contract is enforced rather than assumed.
        try? BundleProtection.propagate(to: bundle.url)

        try await stop(graceful: false)
        Log.vm.notice("VM '\(self.bundle.url.lastPathComponent, privacy: .public)' suspended")
    }

    /// Discards any saved state so the next ``start()`` cold-
    /// boots even if a suspend file is present.
    ///
    /// Synchronous because the underlying operation is a single
    /// `FileManager.removeItem` call — no VM state is mutated,
    /// so the caller doesn't benefit from the concurrency-aware
    /// machinery the lifecycle methods share.
    ///
    /// - Returns: `true` if a saved-state file was removed,
    ///   `false` if there was nothing to discard. Lets callers
    ///   render "already discarded" in their UX without a round
    ///   trip.
    @discardableResult
    public func discardSavedState() -> Bool {
        let url = bundle.savedStateURL
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            Log.vm.notice("Discarded saved-state file for '\(self.bundle.url.lastPathComponent, privacy: .public)'")
            return true
        } catch {
            Log.vm.warning("Failed to discard saved state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Resumes from a saved-state file when one exists; otherwise
    /// cold-boots. Call this in place of ``start()`` whenever the
    /// caller wants "pick up where the user left off" semantics
    /// (the GUI workspace window, `spook start` without explicit
    /// flags).
    ///
    /// ## Delete-on-restore semantics
    ///
    /// The save-file is deleted **immediately after
    /// `restoreMachineStateFrom` returns**, regardless of whether
    /// restore succeeded or failed — matching the pattern from
    /// Apple's own sample code ("Running macOS in a Virtual
    /// Machine on Apple Silicon"):
    ///
    /// > Remove the saved file. Whether success or failure, the
    /// > state no longer matches the VM's disk.
    ///
    /// The consequence: a second `startOrResume()` on the same
    /// bundle cold-boots, mirroring macOS's native
    /// "safe-sleep → wake → sleep again" behaviour. We delete
    /// **before** `resume()` rather than after: if `resume` itself
    /// throws, we've already removed the stale file so the next
    /// start isn't trapped trying to restore from something that
    /// couldn't be resumed.
    ///
    /// ## Fallback on failure
    ///
    /// On restore error we fall through to a cold boot so the
    /// user never gets stuck at "can't resume, can't cold-boot."
    /// Host-OS upgrades can invalidate save-file compatibility —
    /// Apple documents this in the `restoreMachineStateFrom`
    /// failure list ("the file contents are incompatible with
    /// the current configuration"):
    /// <https://developer.apple.com/documentation/virtualization/vzvirtualmachine/restoremachinestatefrom(url:)>.
    public func startOrResume(startUpFromMacOSRecovery recovery: Bool = false) async throws {
        guard vzVM != nil else { throw VirtualMachineInvalidatedError() }
        let savedURL = bundle.savedStateURL
        let hasSaved = FileManager.default.fileExists(atPath: savedURL.path)

        if hasSaved && !recovery {
            let restoreError: Error?
            do {
                try await restoreState(from: savedURL)
                restoreError = nil
            } catch {
                restoreError = error
            }

            // Delete the save-file unconditionally — matches
            // Apple's sample. A successful restore means the
            // guest will write to disk next and diverge from the
            // saved memory snapshot; a failed restore means the
            // file is invalid and should not be retried.
            try? FileManager.default.removeItem(at: savedURL)

            if restoreError == nil {
                try await resume()
                return
            } else {
                Log.vm.warning(
                    "Restore failed (\(String(describing: restoreError), privacy: .public)) — falling back to cold boot"
                )
                // fall through to `start()` below
            }
        }

        try await start(startUpFromMacOSRecovery: recovery)
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
