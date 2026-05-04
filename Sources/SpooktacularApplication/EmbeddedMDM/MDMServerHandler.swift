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

// `MDMCommand` lives in MDMCommand.swift.
// `MDMCommandResponseStatus` lives in MDMCommandResponse.swift.
