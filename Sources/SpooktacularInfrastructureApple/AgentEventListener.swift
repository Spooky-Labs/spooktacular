import Foundation
@preconcurrency import Virtualization
import SpooktacularCore

/// Apple-native host-side receiver for the guest → host event
/// channel.
///
/// Wraps `VZVirtioSocketListener` + `VZVirtioSocketListenerDelegate`
/// — Apple's documented pattern for accepting guest-initiated
/// vsock connections. When the guest agent boots (macOS or Linux
/// alike), it dials `VMADDR_CID_HOST` on port ``listenerPort``;
/// this class accepts the connection, reads length-prefixed
/// `GuestEvent` frames via ``AgentFrameCodec``, and republishes
/// them as an `AsyncThrowingStream<GuestEvent, Error>`.
///
/// ## Why `VZVirtioSocketListener` instead of `connect(toPort:)`
///
/// Apple's `VZVirtioSocketDevice.connect(toPort:)` documents
/// that it "does nothing" when the guest isn't listening on the
/// specified port — the host-initiated path silently no-ops in
/// the boot-race window. `VZVirtioSocketListener` inverts this:
/// the guest declares readiness by dialing in, and the host is
/// guaranteed to learn about it via the delegate. That matches
/// "the guest pushes metrics as soon as it can" without any
/// retry / probe loop on the host.
///
/// Apple's own docs say:
/// > "An object that listens for port-based connection requests
/// > from the guest operating system." — [VZVirtioSocketListener](
/// > https://developer.apple.com/documentation/virtualization/vzvirtiosocketlistener)
///
/// ## Lifecycle
///
/// `VirtualMachine.start()` installs the listener after the VM
/// enters `.running`; `VirtualMachine.stop()` removes it via
/// `removeSocketListener(forPort:)` before teardown. Between
/// those bookends the same listener accepts any number of
/// reconnects from the guest — for example, after the systemd
/// unit restarts the agent on a crash.
@MainActor
public final class AgentEventListener: NSObject {

    /// Vsock port the agent dials to push events. Distinct from
    /// ports 9470/9471/9472 that carry host-initiated RPC so
    /// there's no ambiguity between the two channel models.
    public static let listenerPort: UInt32 = 9469

    /// Latest inbound connection from the guest, replaced on
    /// reconnect. Kept weak-adjacent — the class itself holds
    /// the strong reference via the Apple-provided
    /// `VZVirtioSocketConnection` object.
    private var connection: VZVirtioSocketConnection?

    /// Continuation for the currently subscribed consumer.
    /// Only one consumer at a time (the workspace stats model);
    /// resubscribing cancels the previous stream cleanly.
    private var continuation: AsyncThrowingStream<GuestEvent, Error>.Continuation?

    private let socketDevice: VZVirtioSocketDevice
    private let listener: VZVirtioSocketListener

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        self.listener = VZVirtioSocketListener()
        super.init()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: Self.listenerPort)
    }

    /// Subscribes to decoded events from the current (or next)
    /// guest connection. If the guest reconnects, the stream
    /// stays open and resumes yielding events from the new
    /// connection — the consumer does not see the reconnect.
    public func events() -> AsyncThrowingStream<GuestEvent, Error> {
        AsyncThrowingStream { continuation in
            // Replace any prior continuation — the caller took
            // a fresh subscription.
            self.continuation?.finish()
            self.continuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuation = nil
                }
            }
            // If a connection is already in flight (e.g., the
            // agent dialed in before the UI subscribed), wire
            // it up immediately.
            if let connection {
                spawnReader(connection: connection, continuation: continuation)
            }
        }
    }

    /// Tears down the listener. Call from the `VirtualMachine`
    /// stop path so the delegate stops receiving acceptance
    /// callbacks for a VM that's going away.
    public func stop() {
        socketDevice.removeSocketListener(forPort: Self.listenerPort)
        continuation?.finish()
        continuation = nil
        connection = nil
    }

    // MARK: - Reader

    /// Off-main reader task. `VZVirtioSocketConnection.fileDescriptor`
    /// is safe to touch from any thread once the connection is
    /// established — the `@MainActor` requirement applies only
    /// to the `connect`/`setSocketListener` call sites.
    private func spawnReader(
        connection: VZVirtioSocketConnection,
        continuation: AsyncThrowingStream<GuestEvent, Error>.Continuation
    ) {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            continuation.finish(throwing: CocoaError(.fileReadUnknown))
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        Task.detached(priority: .userInitiated) {
            let decoder = JSONDecoder()
            do {
                while !Task.isCancelled {
                    let event = try AgentFrameCodec.decode(
                        GuestEvent.self,
                        from: { want in
                            // FileHandle.read(upToCount:) returns
                            // up to `want` bytes — we loop until
                            // we have exactly `want` or observe
                            // EOF, because the codec expects the
                            // caller to honor the length
                            // contract.
                            var acc = Data()
                            acc.reserveCapacity(want)
                            while acc.count < want {
                                guard let chunk = try handle.read(upToCount: want - acc.count),
                                      !chunk.isEmpty else {
                                    return acc
                                }
                                acc.append(chunk)
                            }
                            return acc
                        },
                        decoder: decoder
                    )
                    continuation.yield(event)
                }
            } catch AgentFrameCodec.DecodeError.unexpectedEOF {
                // Clean close — agent shut down or VM stopped.
                // Don't finish the stream with an error; the
                // listener may still accept a fresh connection.
                return
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

extension AgentEventListener: VZVirtioSocketListenerDelegate {

    /// Apple's accept callback. Returning `true` hands the
    /// connection object to our reader task.
    ///
    /// Apple's docs:
    /// > "If you don't implement this method, the virtual
    /// > machine refuses all connection requests as if this
    /// > method returned false." — [VZVirtioSocketListenerDelegate
    /// > .listener(_:shouldAcceptNewConnection:from:)](
    /// > https://developer.apple.com/documentation/virtualization/vzvirtiosocketlistenerdelegate/listener(_:shouldacceptnewconnection:from:))
    ///
    /// So implementing it is mandatory. We accept
    /// unconditionally from the guest that owns this device;
    /// trust is boot-time (we instantiated the socket device
    /// for one VM, and only that VM's guest can reach us on
    /// the returned connection).
    public nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        // Bounce onto the main actor to update our connection
        // and wake any waiting consumer.
        Task { @MainActor in
            self.connection?.close()
            self.connection = connection
            if let continuation = self.continuation {
                self.spawnReader(connection: connection, continuation: continuation)
            }
        }
        return true
    }
}
