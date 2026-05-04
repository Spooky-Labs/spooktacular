import Foundation
@preconcurrency import Virtualization
import SpooktacularCore
import os

/// Apple-native host-side receiver for the guest → host event
/// channel.
///
/// Wraps `VZVirtioSocketListener` + `VZVirtioSocketListenerDelegate`
/// — Apple's documented pattern for accepting guest-initiated
/// vsock connections. When the guest agent boots (macOS or Linux
/// alike), it dials `VMADDR_CID_HOST` on port ``listenerPort``.
/// This class:
///
///   1. Accepts the inbound connection via the delegate.
///   2. Runs a long-lived reader task that decodes
///      length-prefixed `GuestEvent` frames via
///      ``AgentFrameCodec``.
///   3. Broadcasts each decoded event to every current
///      subscriber (multiple consumers supported — the GUI
///      chart AND the VMStreamingServer republisher both read
///      from the same stream without yanking events from each
///      other).
///   4. On disconnect, waits for the next reconnect — the
///      listener stays registered.
///
/// ## Why a persistent reader, not per-subscriber
///
/// Earlier revisions only spawned a reader when a subscriber
/// registered. That meant:
///
/// - A guest that dialed in before the UI opened its stats
///   view got its connection accepted, then its fd closed
///   because there was no subscriber yet. Frames were lost,
///   and the connection stayed half-dead until reconnect.
/// - Two subscribers couldn't coexist — `events()` replaced
///   the single internal continuation.
///
/// The multi-consumer bus fixes both.
@MainActor
public final class AgentEventListener: NSObject {

    /// Vsock port the agent dials to push events.
    public static let listenerPort: UInt32 = 9469

    private static let log = Logger(
        subsystem: "com.spooktacular.infra",
        category: "agent-event-listener"
    )

    private let socketDevice: VZVirtioSocketDevice
    private let listener: VZVirtioSocketListener
    private var activeConnection: VZVirtioSocketConnection?
    private var readerTask: Task<Void, Never>?
    private var subscribers: [UUID: AsyncThrowingStream<GuestEvent, Error>.Continuation] = [:]

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        self.listener = VZVirtioSocketListener()
        super.init()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: Self.listenerPort)
        Self.log.notice("Listener registered on vsock:\(Self.listenerPort, privacy: .public)")
    }

    /// Subscribes to the decoded event stream. Multiple
    /// subscribers share the same underlying connection; each
    /// gets its own `AsyncThrowingStream` that yields the same
    /// events in the same order.
    public func events() -> AsyncThrowingStream<GuestEvent, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            self.subscribers[id] = continuation
            Self.log.notice("Subscriber \(id.uuidString.prefix(8), privacy: .public) added (total=\(self.subscribers.count, privacy: .public))")
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.subscribers.removeValue(forKey: id)
                    Self.log.notice("Subscriber \(id.uuidString.prefix(8), privacy: .public) removed")
                }
            }
        }
    }

    /// Tears down the listener. Call from the `VirtualMachine`
    /// stop path so the delegate stops receiving acceptance
    /// callbacks for a VM that's going away.
    public func stop() {
        Self.log.notice("Stopping listener on vsock:\(Self.listenerPort, privacy: .public)")
        socketDevice.removeSocketListener(forPort: Self.listenerPort)
        readerTask?.cancel()
        readerTask = nil
        activeConnection?.close()
        activeConnection = nil
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    // MARK: - Reader

    /// Installs the accepted connection and spawns the reader
    /// task. Called from the delegate on the main actor.
    fileprivate func adopt(connection: VZVirtioSocketConnection) {
        Self.log.notice("Guest dialed in — adopting connection (fd=\(connection.fileDescriptor, privacy: .public))")

        // If there's already a connection (rare — should happen
        // only on a rapid-reconnect edge case), tear it down.
        readerTask?.cancel()
        activeConnection?.close()
        activeConnection = connection

        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            Self.log.error("dup(fd) failed — connection unusable")
            return
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        readerTask = Task.detached(priority: .userInitiated) { [weak self] in
            let decoder = JSONDecoder()
            var frameCount = 0
            do {
                while !Task.isCancelled {
                    let event = try AgentFrameCodec.decode(
                        GuestEvent.self,
                        from: { want in
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
                    frameCount += 1
                    await self?.broadcast(event, frameCount: frameCount)
                }
            } catch AgentFrameCodec.DecodeError.unexpectedEOF {
                await MainActor.run {
                    Self.log.notice("Reader: clean EOF after \(frameCount, privacy: .public) frames — waiting for next connection")
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    Self.log.error("Reader: error after \(frameCount, privacy: .public) frames — \(message, privacy: .public)")
                }
            }
        }
    }

    /// Fan-out helper. Yields the event to every subscriber and
    /// logs the broadcast. The first frame log line is the user-
    /// visible confirmation that the pipeline is working
    /// end-to-end.
    private func broadcast(_ event: GuestEvent, frameCount: Int) {
        if frameCount == 1 {
            Self.log.notice("First event received from guest — pipeline live, \(self.subscribers.count, privacy: .public) subscriber(s)")
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}

extension AgentEventListener: VZVirtioSocketListenerDelegate {

    /// Apple's accept callback. Returning `true` hands the
    /// connection to our reader; `false` would drop it.
    ///
    /// Apple requires this method to be implemented — if the
    /// delegate protocol method is absent, the VM refuses all
    /// connections. See
    /// https://developer.apple.com/documentation/virtualization/vzvirtiosocketlistenerdelegate/listener(_:shouldacceptnewconnection:from:)
    public nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        // `VZVirtioSocketConnection` isn't Sendable. Ferry the
        // reference through an explicit `@unchecked Sendable`
        // box; the receiving main-actor hop touches it only
        // with actor-ensured exclusivity.
        let box = UnsafeConnectionBox(connection: connection)
        Task { @MainActor in
            self.adopt(connection: box.connection)
        }
        return true
    }
}

/// `VZVirtioSocketConnection` is not `Sendable` (Obj-C class
/// bridged without `@Sendable` or `@MainActor` isolation). The
/// box lets us hand it across the main-actor hop for the
/// `adopt(connection:)` call — we only touch it on the main
/// actor after the hop, so the `@unchecked` assertion is
/// accurate.
private struct UnsafeConnectionBox: @unchecked Sendable {
    let connection: VZVirtioSocketConnection
}
