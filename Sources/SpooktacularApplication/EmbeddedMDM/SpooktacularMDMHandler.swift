import Foundation
import os

/// The default ``MDMServerHandler`` that wires
/// ``MDMDeviceStore`` + ``MDMCommandQueue`` into the four
/// transport entry points the protocol defines.
///
/// ## Responsibilities
///
/// - **Authenticate** → record the device, mint its slot in
///   the directory.
/// - **TokenUpdate** → update push-token metadata + bump
///   lastSeen.
/// - **CheckOut** → flag the device, *and* drop its queue
///   (any commands we still had pending are undeliverable).
/// - **Command poll (Idle)** → bump lastSeen, hand back the
///   next pending command.
/// - **Command response** → bump lastSeen, dequeue the
///   in-flight command on Acknowledged/Error, leave it put on
///   NotNow, ignore on Idle (Idle is "I have nothing to ack",
///   which is irrelevant to the response handler — the
///   transport routes it through `nextCommand` instead).
///
/// ## What this *doesn't* do
///
/// - Audit. `AuditStore` is intentionally not wired in here so
///   this type stays pure (no FS dependencies). The host's
///   `MDMServer` will pump events through `AuditStore` itself
///   at the transport boundary — see Phase 3c.
/// - Auth. Any caller that reaches this handler has already
///   passed the transport-layer mTLS check. The check itself
///   is the server's job.
public actor SpooktacularMDMHandler: MDMServerHandler {

    private let deviceStore: MDMDeviceStore
    private let commandQueue: MDMCommandQueue
    private let logger: Logger

    /// - Parameters:
    ///   - deviceStore: shared with operator UI / CLI for "list
    ///     enrolled devices" reads.
    ///   - commandQueue: shared with the user-data dispatcher
    ///     so it can `enqueue` directly.
    ///   - logger: subsystem-scoped logger; the server passes
    ///     in its own from `os.Logger`.
    public init(
        deviceStore: MDMDeviceStore,
        commandQueue: MDMCommandQueue,
        logger: Logger = Logger(
            subsystem: "com.spookylabs.spooktacular",
            category: "mdm.handler"
        )
    ) {
        self.deviceStore = deviceStore
        self.commandQueue = commandQueue
        self.logger = logger
    }

    // MARK: - MDMServerHandler

    public func didReceiveAuthenticate(
        _ message: MDMCheckInMessage.Authenticate
    ) async {
        logger.notice(
            "Authenticate UDID=\(message.udid, privacy: .public) topic=\(message.topic, privacy: .public)"
        )
        await deviceStore.upsertAuthenticate(message)
    }

    public func didReceiveTokenUpdate(
        _ message: MDMCheckInMessage.TokenUpdate
    ) async {
        logger.notice(
            "TokenUpdate UDID=\(message.udid, privacy: .public) hasPushToken=\(message.pushToken != nil)"
        )
        await deviceStore.upsertTokenUpdate(message)
    }

    public func didReceiveCheckOut(
        _ message: MDMCheckInMessage.CheckOut
    ) async {
        logger.notice(
            "CheckOut UDID=\(message.udid, privacy: .public)"
        )
        await deviceStore.markCheckedOut(message.udid)
        // Anything still pending for this device is stranded;
        // wipe the queue. The handler doesn't try to be clever
        // — operators who want to inspect the dropped commands
        // can read audit instead.
        await commandQueue.removeAll(forUDID: message.udid)
    }

    public func nextCommand(forUDID udid: String) async -> MDMCommand? {
        await deviceStore.touchLastSeen(udid)
        let command = await commandQueue.dequeueNext(forUDID: udid)
        if let command {
            logger.info(
                "Dispatching command \(command.commandUUID.uuidString, privacy: .public) [\(command.kind.requestType, privacy: .public)] to UDID=\(udid, privacy: .public)"
            )
        }
        return command
    }

    public func didReceiveCommandResponse(
        forUDID udid: String,
        commandUUID: UUID,
        status: MDMCommandResponseStatus
    ) async {
        await deviceStore.touchLastSeen(udid)
        switch status {
        case .acknowledged:
            logger.notice(
                "Acknowledged \(commandUUID.uuidString, privacy: .public) by UDID=\(udid, privacy: .public)"
            )
            await commandQueue.acknowledge(
                commandUUID: commandUUID,
                forUDID: udid
            )
        case .error:
            logger.error(
                "Error response for \(commandUUID.uuidString, privacy: .public) UDID=\(udid, privacy: .public)"
            )
            await commandQueue.markFailed(
                commandUUID: commandUUID,
                forUDID: udid
            )
        case .notNow:
            // Leave in-flight — the device will retry on the
            // next poll. Only log so operators can tell when
            // a device is sticky on a particular command.
            logger.info(
                "NotNow on \(commandUUID.uuidString, privacy: .public) UDID=\(udid, privacy: .public) — leaving in-flight"
            )
        case .idle:
            // Idle means "I'm just polling, nothing to ack" —
            // the transport routes those through nextCommand
            // instead of here. If we somehow get one, ignore.
            break
        }
    }

    // MARK: - Operator-facing helpers

    /// Enqueue a command for a specific device. Used by the
    /// user-data dispatcher and operator CLI; the protocol
    /// itself is read-only from the handler's side.
    public func enqueue(_ command: MDMCommand, forUDID udid: String) async {
        logger.notice(
            "Enqueuing \(command.commandUUID.uuidString, privacy: .public) [\(command.kind.requestType, privacy: .public)] for UDID=\(udid, privacy: .public)"
        )
        await commandQueue.enqueue(command, forUDID: udid)
    }
}
