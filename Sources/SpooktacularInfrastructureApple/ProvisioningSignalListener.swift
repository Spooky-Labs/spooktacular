import Foundation
import Virtualization
import os

/// The guest's report that first-boot provisioning finished.
public struct ProvisioningSignal: Sendable, Equatable {

    /// Exit status of the guest's `first-boot.sh`.
    public let exitCode: Int32

    /// Whether provisioning completed without error.
    public var succeeded: Bool { exitCode == 0 }

    /// Frame marker (`'S'`), distinguishing a readiness frame from
    /// stray bytes arriving on the port.
    private static let magic: UInt8 = 0x53

    /// The wire frame's exact length: marker plus a big-endian `Int32`.
    private static let frameLength = 5

    /// Creates a signal.
    ///
    /// - Parameter exitCode: The first-boot script's exit status.
    public init(exitCode: Int32) {
        self.exitCode = exitCode
    }

    /// Encodes a signal as the five-byte wire frame.
    ///
    /// - Parameter exitCode: The first-boot script's exit status.
    /// - Returns: `0x53` followed by the exit code, big-endian.
    public static func encode(exitCode: Int32) -> Data {
        var data = Data([magic])
        withUnsafeBytes(of: exitCode.bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// Decodes a wire frame.
    ///
    /// - Parameter data: Bytes read from the guest connection.
    /// - Returns: The signal, or `nil` when the frame is malformed.
    public static func decode(_ data: Data) -> ProvisioningSignal? {
        guard data.count == frameLength, data.first == magic else { return nil }
        let raw = data.dropFirst().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return ProvisioningSignal(exitCode: Int32(bitPattern: raw))
    }
}

/// Listens for the guest's end-of-provisioning signal.
///
/// The alternative — poll for an IP, then for SSH, then for a marker
/// file — is exactly the timing race this project forbids. Here the
/// guest dials the host the moment its first-boot script exits, so
/// "provisioning finished" is an event carrying an exit code rather
/// than an inference drawn from a timeout.
///
/// Uses vsock port 9470. Port 9469 belongs to ``AgentEventListener``,
/// which holds a single connection for the Guest Tools event stream.
@MainActor
public final class ProvisioningSignalListener: NSObject {

    /// The vsock port the guest dials when provisioning completes.
    ///
    /// `nonisolated` so the guest-side contract can be referenced
    /// without hopping to the main actor.
    public nonisolated static let listenerPort: UInt32 = 9470

    private let socketDevice: VZVirtioSocketDevice
    private let listener: VZVirtioSocketListener
    private let onSignal: @MainActor (ProvisioningSignal) -> Void

    /// `nonisolated` so the framework's off-main-actor accept callback
    /// can log without hopping actors.
    private nonisolated static let log = Logger(
        subsystem: "com.spooktacular",
        category: "provision-signal"
    )

    /// Registers the listener on a running VM's socket device.
    ///
    /// - Parameters:
    ///   - socketDevice: The VM's virtio socket device.
    ///   - onSignal: Called on the main actor when the guest reports.
    public init(
        socketDevice: VZVirtioSocketDevice,
        onSignal: @escaping @MainActor (ProvisioningSignal) -> Void
    ) {
        self.socketDevice = socketDevice
        self.listener = VZVirtioSocketListener()
        self.onSignal = onSignal
        super.init()
        listener.delegate = self
        socketDevice.setSocketListener(listener, forPort: Self.listenerPort)
        Self.log.notice(
            "Readiness listener registered on vsock:\(Self.listenerPort, privacy: .public)"
        )
    }

    /// Removes the listener.
    ///
    /// Safe to call more than once: the framework documents
    /// `removeSocketListener(forPort:)` as doing nothing when no
    /// listener is registered.
    public func stop() {
        socketDevice.removeSocketListener(forPort: Self.listenerPort)
    }
}

extension ProvisioningSignalListener: VZVirtioSocketListenerDelegate {

    /// Accepts the guest's connection and reads its frame.
    ///
    /// Apple requires this callback to "return a result as quickly as
    /// possible", so it duplicates the descriptor and hands the read to
    /// a task rather than doing it inline. The callback is
    /// `nonisolated` because the framework calls it off the main actor;
    /// only the duplicated descriptor — an `Int32`, and so `Sendable` —
    /// crosses to the main-actor hop, which is why this needs none of
    /// the connection-boxing ``AgentEventListener`` does.
    public nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let descriptor = dup(connection.fileDescriptor)
        guard descriptor >= 0 else {
            Self.log.error("Could not duplicate the readiness connection descriptor")
            return false
        }
        Task { @MainActor in
            defer { close(descriptor) }
            var buffer = [UInt8](repeating: 0, count: 5)
            let count = read(descriptor, &buffer, buffer.count)
            guard count == buffer.count,
                  let signal = ProvisioningSignal.decode(Data(buffer)) else {
                Self.log.error("Malformed readiness frame from guest (read \(count) bytes)")
                return
            }
            Self.log.notice(
                "Guest reported provisioning exit=\(signal.exitCode, privacy: .public)"
            )
            self.onSignal(signal)
        }
        return true
    }
}
