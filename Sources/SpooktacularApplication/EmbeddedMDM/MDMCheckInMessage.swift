import Foundation

/// One of the canonical MDM check-in message types Apple's
/// `mdmclient` sends to a server's `CheckInURL` over the
/// lifecycle of an enrolled device.
///
/// ## Wire shape
///
/// Every check-in is an XML plist with at minimum a `MessageType`
/// key. Each variant below carries the additional fields we
/// extract from that plist for routing and identity tracking.
///
/// ```
/// {
///   MessageType    = Authenticate | TokenUpdate | CheckOut | …
///   UDID           = <device UDID>          (always present)
///   Topic          = com.apple.mgmt.External.<UUID>
///   ...message-type-specific fields...
/// }
/// ```
///
/// ## What's deliberately not modeled (yet)
///
/// `mdmclient` can send other message types we don't act on
/// during enrollment + InstallApplication delivery: `LoginRequest`,
/// `LogoutRequest`, `DeclarativeManagement`, `GetBootstrapToken`,
/// `SetBootstrapToken`. They land in the catch-all `unsupported`
/// case so the server can log + 200 OK them rather than blowing
/// up — Apple expects unknown message types to be tolerated.
public enum MDMCheckInMessage: Sendable, Equatable {

    /// First message after profile install. Establishes device
    /// identity. We record the device for the first time here,
    /// keyed by ``udid``.
    case authenticate(Authenticate)

    /// Sent at enrollment + on every subsequent boot if APNs is
    /// configured. Carries the push token / unlock token / awake
    /// token. We don't use APNs (poll-only design — see Phase 5),
    /// so we just persist whatever's here for diagnostic
    /// completeness.
    case tokenUpdate(TokenUpdate)

    /// Device removed our profile; tear down its queue + cert.
    case checkOut(CheckOut)

    /// Anything else `mdmclient` may send. The server logs and
    /// 200 OKs the request rather than failing.
    case unsupported(messageType: String, udid: String?)

    // MARK: - Common-prefix payload

    public struct Authenticate: Sendable, Equatable {
        /// Device UDID — the primary key by which we track
        /// enrolled VMs.
        public let udid: String
        /// MDM topic the device thinks it's enrolled under.
        /// Should match the topic in the enrollment profile we
        /// generated for this VM.
        public let topic: String
        /// Hardware-reported model identifier. Useful for
        /// diagnostics, not for routing.
        public let model: String?
        /// macOS version on the device.
        public let osVersion: String?

        public init(udid: String, topic: String, model: String?, osVersion: String?) {
            self.udid = udid
            self.topic = topic
            self.model = model
            self.osVersion = osVersion
        }
    }

    public struct TokenUpdate: Sendable, Equatable {
        public let udid: String
        public let topic: String
        /// APNs push token. We don't use it (poll-only design)
        /// but persist it in case future versions add APNs.
        public let pushToken: Data?
        /// Magic value mdmclient expects in `Push` MDM messages.
        public let pushMagic: String?
        /// Unlock token returned to administrators after a
        /// FileVault-protected VM boots into the recovery
        /// environment. Optional in practice for VMs.
        public let unlockToken: Data?

        public init(
            udid: String,
            topic: String,
            pushToken: Data?,
            pushMagic: String?,
            unlockToken: Data?
        ) {
            self.udid = udid
            self.topic = topic
            self.pushToken = pushToken
            self.pushMagic = pushMagic
            self.unlockToken = unlockToken
        }
    }

    public struct CheckOut: Sendable, Equatable {
        public let udid: String
        public let topic: String

        public init(udid: String, topic: String) {
            self.udid = udid
            self.topic = topic
        }
    }

    // MARK: - Convenience

    /// UDID of the device that sent the message, if the message
    /// type carries one. Routing layer keys on this.
    public var udid: String? {
        switch self {
        case .authenticate(let a): a.udid
        case .tokenUpdate(let t): t.udid
        case .checkOut(let c): c.udid
        case .unsupported(_, let udid): udid
        }
    }
}

// MARK: - Plist decoding

extension MDMCheckInMessage {

    /// Decodes a plist body (XML or binary) from a check-in
    /// POST into a typed message. Throws when the body isn't
    /// a dictionary or `MessageType` is missing — both
    /// indicate a malformed request the server should 400 on.
    public static func decode(plistBody: Data) throws -> MDMCheckInMessage {
        let raw = try PropertyListSerialization.propertyList(
            from: plistBody,
            options: [],
            format: nil
        )
        guard let dict = raw as? [String: Any] else {
            throw MDMCheckInDecodeError.notADictionary
        }
        guard let messageType = dict["MessageType"] as? String else {
            throw MDMCheckInDecodeError.missingMessageType
        }
        let udid = dict["UDID"] as? String
        let topic = dict["Topic"] as? String

        switch messageType {
        case "Authenticate":
            guard let udid, let topic else {
                throw MDMCheckInDecodeError.missingRequiredField(
                    messageType: messageType,
                    field: udid == nil ? "UDID" : "Topic"
                )
            }
            return .authenticate(.init(
                udid: udid,
                topic: topic,
                model: dict["Model"] as? String,
                osVersion: dict["OSVersion"] as? String
            ))

        case "TokenUpdate":
            guard let udid, let topic else {
                throw MDMCheckInDecodeError.missingRequiredField(
                    messageType: messageType,
                    field: udid == nil ? "UDID" : "Topic"
                )
            }
            return .tokenUpdate(.init(
                udid: udid,
                topic: topic,
                pushToken: dict["Token"] as? Data,
                pushMagic: dict["PushMagic"] as? String,
                unlockToken: dict["UnlockToken"] as? Data
            ))

        case "CheckOut":
            guard let udid, let topic else {
                throw MDMCheckInDecodeError.missingRequiredField(
                    messageType: messageType,
                    field: udid == nil ? "UDID" : "Topic"
                )
            }
            return .checkOut(.init(udid: udid, topic: topic))

        default:
            return .unsupported(messageType: messageType, udid: udid)
        }
    }
}

/// Errors thrown by ``MDMCheckInMessage/decode(plistBody:)``.
/// All of these correspond to "the request body is malformed
/// in a way the server should reject with HTTP 400" — none
/// are recoverable.
public enum MDMCheckInDecodeError: Error, Equatable, Sendable {
    /// Top-level plist wasn't a dictionary.
    case notADictionary
    /// `MessageType` key was absent or not a string.
    case missingMessageType
    /// A required field for the given message type was missing.
    case missingRequiredField(messageType: String, field: String)
}
