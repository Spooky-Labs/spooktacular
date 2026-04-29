import Foundation

/// Boundary the embedded MDM HTTP server delegates to. The
/// transport (`Network.framework` listener, plist serialization,
/// HTTP framing) lives in `SpooktacularInfrastructureApple`; the
/// policy (which commands to send, when to mark a device
/// enrolled, how to scrub a checked-out device's queue) lives
/// behind this protocol so it can be implemented + unit tested
/// without spinning up a real listener.
///
/// The protocol is intentionally tiny — exactly the four
/// operations the wire protocol forces:
///
/// | mdmclient action            | Handler call                       |
/// |-----------------------------|------------------------------------|
/// | POST /mdm/checkin {Authenticate}  | ``didReceiveAuthenticate(_:)`` |
/// | POST /mdm/checkin {TokenUpdate}   | ``didReceiveTokenUpdate(_:)``  |
/// | POST /mdm/checkin {CheckOut}      | ``didReceiveCheckOut(_:)``     |
/// | PUT  /mdm/server (idle poll)      | ``nextCommand(forUDID:)``      |
///
/// Anything else (`unsupported` MessageType variants, malformed
/// bodies, the eventual ServerCommandResponse-with-Error path)
/// is handled at the transport layer with HTTP semantics —
/// outside the policy boundary.
public protocol MDMServerHandler: Sendable {

    /// First contact from a freshly-enrolled VM. Conforming
    /// implementations register the device, mint its per-device
    /// command queue, and may immediately enqueue an
    /// `InstallApplication` for the user-data pkg (Phase 7).
    func didReceiveAuthenticate(_ message: MDMCheckInMessage.Authenticate) async

    /// Push-token + unlock-token delivery. We don't actually
    /// use APNs (poll-only design — see Phase 5), but persisting
    /// what `mdmclient` sends keeps diagnostics complete and
    /// lets future revisions opt into push without a wire-format
    /// migration.
    func didReceiveTokenUpdate(_ message: MDMCheckInMessage.TokenUpdate) async

    /// Device removed our profile; tear down its queue and any
    /// per-device state. After this call, ``nextCommand(forUDID:)``
    /// should return `nil` for the same UDID.
    func didReceiveCheckOut(_ message: MDMCheckInMessage.CheckOut) async

    /// Returns the next pending MDM command for the given
    /// device, or `nil` when the queue is empty. The MDM
    /// protocol uses an HTTP 200 with empty body to signal "no
    /// commands" — the transport layer translates `nil` to that
    /// shape on the wire.
    ///
    /// Conforming implementations are responsible for marking
    /// the command "in-flight" so retries don't double-deliver;
    /// the transport calls back via
    /// ``didReceiveCommandResponse(forUDID:commandUUID:status:)``
    /// once the device acks the result.
    func nextCommand(forUDID udid: String) async -> MDMCommand?

    /// Acknowledgement from the device for a previously-issued
    /// command. `status` mirrors Apple's documented
    /// ``MDMCommandResponseStatus`` values.
    func didReceiveCommandResponse(
        forUDID udid: String,
        commandUUID: UUID,
        status: MDMCommandResponseStatus
    ) async
}

/// A command queued for delivery to a specific enrolled device.
/// Phase 3 surfaces the type; Phase 4 fills in the cases.
public struct MDMCommand: Sendable, Equatable {
    /// Stable UUID Apple's MDM protocol uses to correlate
    /// command + ServerCommandResponse acknowledgements.
    public let commandUUID: UUID

    /// The actual command to run. Phase 4 expands this enum;
    /// for now the placeholder lets the rest of the protocol
    /// compile.
    public let kind: Kind

    public init(commandUUID: UUID = UUID(), kind: Kind) {
        self.commandUUID = commandUUID
        self.kind = kind
    }

    public enum Kind: Sendable, Equatable {
        /// Phase 4 will replace this with concrete cases:
        /// `.installApplication(manifestURL: URL, identifier: String)`,
        /// `.installProfile(payload: Data)`, etc.
        case placeholder
    }
}

/// Status field of a ServerCommandResponse — what Apple's
/// MDM Protocol Reference calls the four legal values for the
/// `Status` plist key.
public enum MDMCommandResponseStatus: String, Sendable, Equatable {
    /// Command completed successfully.
    case acknowledged = "Acknowledged"

    /// Device is processing; will report final status in a
    /// subsequent poll.
    case notNow = "NotNow"

    /// Command failed permanently. ErrorChain in the response
    /// plist explains why.
    case error = "Error"

    /// Device is unreachable / shut down. Never sent by
    /// `mdmclient` itself; emitted by the server when the
    /// command times out without a response.
    case idle = "Idle"
}
