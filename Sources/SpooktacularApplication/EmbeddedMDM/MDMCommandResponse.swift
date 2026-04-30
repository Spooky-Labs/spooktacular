import Foundation

/// A device's reply to a previously-issued ``MDMCommand``.
/// `mdmclient` POSTs this plist to the same `/mdm/server`
/// endpoint it picks commands up from — the URL is overloaded
/// by HTTP method (GET = "give me a command", PUT = "here's the
/// result of the last one").
///
/// ## Wire shape
///
/// ```
/// <dict>
///     <key>CommandUUID</key>
///     <string>UUID</string>
///     <key>Status</key>
///     <string>Acknowledged|Error|NotNow|Idle</string>
///     <key>UDID</key>
///     <string>device-UDID</string>
///     <!-- when Status=Error: -->
///     <key>ErrorChain</key>
///     <array>
///         <dict>
///             <key>ErrorCode</key>     <integer>...</integer>
///             <key>ErrorDomain</key>   <string>...</string>
///             <key>LocalizedDescription</key>  <string>...</string>
///             <key>USEnglishDescription</key>  <string>...</string>
///         </dict>
///     </array>
///     <!-- when Status=NotNow: empty body apart from these
///          three required keys. The device retries on a later
///          poll. -->
/// </dict>
/// ```
///
/// ## Routing
///
/// The `Idle` status is special: `mdmclient` sends an Idle reply
/// when it has *no* previous command to acknowledge — i.e. it's
/// just polling for new work. The transport layer translates an
/// Idle response into ``MDMServerHandler/nextCommand(forUDID:)``
/// directly (no `didReceiveCommandResponse` callback) since
/// there's no previous command to correlate.
public struct MDMCommandResponse: Sendable, Equatable {

    /// Echoed from the original command. Used by the host to
    /// look up the in-flight command in the queue and mark it
    /// completed / failed.
    public let commandUUID: UUID

    /// Device UDID, identifies which queue this response
    /// belongs to.
    public let udid: String

    /// Outcome.
    public let status: MDMCommandResponseStatus

    /// When `status == .error`, the error chain Apple's
    /// `mdmclient` produces. Empty otherwise.
    public let errorChain: [MDMCommandError]

    public init(
        commandUUID: UUID,
        udid: String,
        status: MDMCommandResponseStatus,
        errorChain: [MDMCommandError] = []
    ) {
        self.commandUUID = commandUUID
        self.udid = udid
        self.status = status
        self.errorChain = errorChain
    }

    // MARK: - Decoding

    /// Parses an HTTP body into an ``MDMCommandResponse``.
    /// Throws on malformed bodies — the transport layer maps
    /// each error case to HTTP 400.
    public static func decode(plistBody: Data) throws -> MDMCommandResponse {
        let raw = try PropertyListSerialization.propertyList(
            from: plistBody,
            options: [],
            format: nil
        )
        guard let dict = raw as? [String: Any] else {
            throw MDMCommandResponseDecodeError.notADictionary
        }

        guard let udid = dict["UDID"] as? String else {
            throw MDMCommandResponseDecodeError.missingField(field: "UDID")
        }
        guard let statusString = dict["Status"] as? String,
              let status = MDMCommandResponseStatus(rawValue: statusString) else {
            throw MDMCommandResponseDecodeError.invalidStatus(
                value: dict["Status"] as? String ?? ""
            )
        }

        // Idle responses don't echo a CommandUUID — there's no
        // previous command to ack. Fabricate a zero UUID for
        // those so the value type stays simple; the transport
        // layer ignores `commandUUID` for Idle anyway.
        let commandUUID: UUID
        if status == .idle {
            commandUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID()
        } else {
            guard let raw = dict["CommandUUID"] as? String,
                  let parsed = UUID(uuidString: raw) else {
                throw MDMCommandResponseDecodeError.missingField(field: "CommandUUID")
            }
            commandUUID = parsed
        }

        // Parse error chain if present. Tolerant of missing
        // sub-keys (Apple's ErrorChain entries are sparse in
        // practice — ErrorCode / ErrorDomain are usually there
        // but LocalizedDescription often isn't).
        var errors: [MDMCommandError] = []
        if let chain = dict["ErrorChain"] as? [[String: Any]] {
            for entry in chain {
                let code = (entry["ErrorCode"] as? Int) ?? 0
                let domain = (entry["ErrorDomain"] as? String) ?? ""
                let localized = entry["LocalizedDescription"] as? String
                let usEnglish = entry["USEnglishDescription"] as? String
                errors.append(MDMCommandError(
                    code: code,
                    domain: domain,
                    localizedDescription: localized,
                    usEnglishDescription: usEnglish
                ))
            }
        }

        return MDMCommandResponse(
            commandUUID: commandUUID,
            udid: udid,
            status: status,
            errorChain: errors
        )
    }
}

/// One entry from a `ServerCommandResponse`'s `ErrorChain`.
/// Maps directly to the wire shape Apple's MDM Protocol
/// Reference documents.
public struct MDMCommandError: Sendable, Equatable {
    /// `ErrorCode` plist key. Domain-specific integer.
    public let code: Int

    /// `ErrorDomain` plist key. Apple's `mdmclient` uses values
    /// like `MDMErrorDomain`, `NSCocoaErrorDomain`, `MCError` —
    /// we don't enumerate them, just preserve the string for
    /// audit + diagnostics.
    public let domain: String

    /// User-facing string in the device's locale. Apple may
    /// omit this on some failures, especially low-level kernel
    /// rejections.
    public let localizedDescription: String?

    /// Apple's stable English string for the same condition.
    /// Useful for log-grepping across locale-mixed fleets.
    public let usEnglishDescription: String?

    public init(
        code: Int,
        domain: String,
        localizedDescription: String?,
        usEnglishDescription: String?
    ) {
        self.code = code
        self.domain = domain
        self.localizedDescription = localizedDescription
        self.usEnglishDescription = usEnglishDescription
    }
}

/// Status field of a ServerCommandResponse — what Apple's
/// MDM Protocol Reference calls the four legal values for the
/// `Status` plist key.
public enum MDMCommandResponseStatus: String, Sendable, Equatable {

    /// Command completed successfully.
    case acknowledged = "Acknowledged"

    /// Device is busy; will retry processing on the next poll.
    /// We leave the command in-flight — don't dequeue.
    case notNow = "NotNow"

    /// Command failed permanently. ``MDMCommandResponse/errorChain``
    /// explains why.
    case error = "Error"

    /// "I have nothing to ack — give me work." Sent during
    /// idle polls when the device's last command (if any) was
    /// already acked. The transport layer routes Idle to
    /// ``MDMServerHandler/nextCommand(forUDID:)`` for a fresh
    /// command, never to `didReceiveCommandResponse`.
    case idle = "Idle"
}

/// Errors thrown by ``MDMCommandResponse/decode(plistBody:)``.
public enum MDMCommandResponseDecodeError: Error, Equatable, Sendable {
    /// Top-level plist wasn't a dictionary.
    case notADictionary

    /// A required key was absent.
    case missingField(field: String)

    /// `Status` was missing or wasn't one of the four legal
    /// values.
    case invalidStatus(value: String)
}
