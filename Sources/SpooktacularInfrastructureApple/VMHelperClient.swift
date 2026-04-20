import Foundation
import os
import SpooktacularCore

/// Main-app-side client for the bundled
/// `SpooktacularVMHelper.xpc` process (Track J).
///
/// Wraps `NSXPCConnection(serviceName:)` with typed
/// convenience methods, invalidation/interruption handling,
/// and a minimal `ping` round-trip used today for
/// diagnostics and tomorrow as the template for real VM ops
/// (start/stop/pause/resume/save/restore).
///
/// ## Connection shape
///
/// - **One connection per client.** Each `VMHelperClient`
///   owns exactly one `NSXPCConnection`. The helper's
///   `ServiceDelegate` vends a fresh `VMHelperImplementation`
///   per connection, so per-client state (the VMs this
///   client drives) stays isolated even if two callers in
///   the same main-app process open separate clients.
/// - **`launchd`-managed lifecycle.** For a bundled XPC
///   service, `launchd` starts the helper process on first
///   connection and reaps it when this process exits or
///   the connection has been idle long enough. We don't
///   manually spawn or supervise.
/// - **Crash = invalidation.** If the helper crashes,
///   `invalidationHandler` fires. `NSXPCConnection` docs
///   specifically call this out: re-use is forbidden after
///   invalidation, so callers construct a new client.
///   `interruptionHandler` fires on transient interruptions
///   (the next message may re-establish the channel); we
///   log but don't tear down on interruption.
///
/// ## References
///
/// - [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection)
/// - [NSXPCConnection.invalidationHandler](https://developer.apple.com/documentation/foundation/nsxpcconnection/invalidationhandler)
/// - [NSXPCConnection.interruptionHandler](https://developer.apple.com/documentation/foundation/nsxpcconnection/interruptionhandler)
public final class VMHelperClient: @unchecked Sendable {

    /// Snapshot the helper returns from `ping`. Parallels the
    /// protocol's reply-block signature; exposes a single
    /// typed value callers `await` on.
    public struct PingResult: Sendable, Equatable {
        public let pid: Int32
        public let version: String
    }

    /// Reasons ``ping()`` can fail. Kept distinct from the
    /// generic `Error` the NSXPC layer surfaces so callers
    /// can distinguish "helper absent" from "helper crashed
    /// mid-call" in UI.
    public enum ClientError: Error, Sendable, CustomStringConvertible {
        /// The connection invalidated before a reply arrived.
        /// Usually means the helper bundle is missing from
        /// `Contents/XPCServices/` or the code signature
        /// rejected the launch.
        case invalidated
        /// The remote proxy reported an error.
        case remote(Error)

        public var description: String {
            switch self {
            case .invalidated:
                return "VMHelper connection invalidated (helper missing or signature mismatch)"
            case .remote(let error):
                return "VMHelper remote error: \(error.localizedDescription)"
            }
        }
    }

    private static let log = Logger(
        subsystem: "com.spooktacular.app",
        category: "vm-helper-client"
    )

    private let connection: NSXPCConnection

    public init(serviceName: String = VMHelperServiceName.helper) {
        self.connection = NSXPCConnection(serviceName: serviceName)
        self.connection.remoteObjectInterface = NSXPCInterface(with: VMHelperProtocol.self)
        self.connection.interruptionHandler = {
            Self.log.notice("VMHelper connection interrupted (transient)")
        }
        self.connection.invalidationHandler = {
            Self.log.error("VMHelper connection invalidated (terminal)")
        }
        self.connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// Liveness probe. Resolves with the helper's PID and
    /// bundle version, or throws ``ClientError`` if the
    /// connection dropped before a reply arrived.
    ///
    /// Uses a `withCheckedThrowingContinuation` bridge
    /// because `NSXPCConnection.remoteObjectProxyWithErrorHandler`
    /// is a pure completion-handler API — no async/await
    /// overload. The continuation is guarded with a single
    /// `resumed` flag so an error + reply race (very
    /// unlikely but documented) resumes exactly once.
    public func ping() async throws -> PingResult {
        try await withCheckedThrowingContinuation { continuation in
            nonisolated(unsafe) var resumed = false
            let resumeOnce: @Sendable (Result<PingResult, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                resumeOnce(.failure(ClientError.remote(error)))
            } as? VMHelperProtocol
            guard let proxy else {
                resumeOnce(.failure(ClientError.invalidated))
                return
            }
            proxy.ping { pid, version in
                resumeOnce(.success(PingResult(pid: pid, version: version)))
            }
        }
    }
}
