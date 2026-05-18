import Foundation

/// A command queued for delivery to a specific enrolled device.
///
/// MDM commands are sent to a device when it polls
/// `/mdm/server` (the idle endpoint), and the device replies
/// asynchronously via the same endpoint with a
/// ``MDMCommandResponse`` carrying ``MDMCommandResponseStatus``.
///
/// ## Why these specific cases
///
/// We model only the commands the embedded MDM actually issues
/// during normal operation:
///
/// - **`.installEnterpriseApplication`** — the primary user-data
///   path. The host wraps a script as a one-shot pkg, hosts it
///   behind a manifest URL, and pushes the URL via this command.
///   `mdmclient` downloads the manifest, then the pkg, runs
///   `installer`, and ack's. This is *not* `InstallApplication`
///   (which is App Store / VPP only) — `InstallEnterpriseApplication`
///   is Apple's documented command for arbitrary developer-signed
///   pkgs and accepts a manifest URL or inline manifest dict.
///
/// - **`.installProfile`** — push additional configuration
///   profiles after enrollment (egress policy, MDM root CA
///   updates, Setup Assistant restrictions). Inline plist
///   payload, not URL-fetched.
///
/// - **`.removeProfile`** — symmetric to the install path,
///   keyed by `PayloadIdentifier`. The MDM cleans up its own
///   profiles when a tenant unbinds, or operator action revokes
///   a permission profile.
///
/// Anything else (`.deviceLock`, `.eraseDevice`, App Store
/// `InstallApplication` with `iTunesStoreID`, declarative
/// management, etc.) is deliberately out of scope for the MVP —
/// they're either dangerous defaults or solve problems we don't
/// have on host-controlled VMs.
public struct MDMCommand: Sendable, Equatable {

    /// Stable UUID Apple's MDM protocol uses to correlate
    /// command + ServerCommandResponse acknowledgements. Echoed
    /// back unchanged in the device's reply.
    public let commandUUID: UUID

    /// What the device should do.
    public let kind: Kind

    public init(commandUUID: UUID = UUID(), kind: Kind) {
        self.commandUUID = commandUUID
        self.kind = kind
    }

    /// The actual command to dispatch. Each case maps to a
    /// specific `RequestType` string in Apple's MDM Protocol
    /// Reference.
    public enum Kind: Sendable, Equatable {

        /// Install a developer-signed pkg referenced by a
        /// manifest URL the device dereferences with HTTPS.
        ///
        /// Wire `RequestType`: `InstallEnterpriseApplication`.
        ///
        /// - Parameter manifestURL: Points at a Distribution-
        ///   format manifest plist whose `assets[0].url` is the
        ///   pkg itself. Both URLs must be reachable from the
        ///   guest — for the embedded MDM that's the host's
        ///   manifest server.
        /// - Parameter manifestURLPinningCerts: Optional list of
        ///   DER-encoded certs the device must pin against when
        ///   fetching the manifest. Empty array means "trust
        ///   the device's existing root chain" — fine when the
        ///   guest already has the host's MDM CA installed via
        ///   the enrollment profile.
        case installEnterpriseApplication(
            manifestURL: URL,
            manifestURLPinningCerts: [Data]
        )

        /// Install a configuration profile inline (the bytes
        /// are sent in the command, not URL-fetched).
        ///
        /// Wire `RequestType`: `InstallProfile`. The profile
        /// data is base64-encoded into the `Payload` key.
        ///
        /// - Parameter payload: A signed or unsigned
        ///   `.mobileconfig`. Signed is preferred for production
        ///   so receipts stay tamper-evident.
        case installProfile(payload: Data)

        /// Remove an installed profile by identifier.
        ///
        /// Wire `RequestType`: `RemoveProfile`. The
        /// `PayloadIdentifier` matches the
        /// `PayloadIdentifier` used at install time.
        case removeProfile(payloadIdentifier: String)
    }
}

// MARK: - RequestType + wire encoding

extension MDMCommand.Kind {

    /// The MDM `RequestType` string Apple's MDM Protocol
    /// Reference defines for this kind. Goes inside the inner
    /// `Command` dict as the `RequestType` key.
    public var requestType: String {
        switch self {
        case .installEnterpriseApplication: "InstallEnterpriseApplication"
        case .installProfile: "InstallProfile"
        case .removeProfile: "RemoveProfile"
        }
    }

    /// The payload dictionary for this command's inner
    /// `Command` plist. Each case fills in the type-specific
    /// keys; ``MDMCommand/wirePlist()`` wraps them in the outer
    /// `CommandUUID`+`Command` envelope.
    fileprivate func commandDictionary() -> [String: Any] {
        switch self {
        case .installEnterpriseApplication(let manifestURL, let pinningCerts):
            var dict: [String: Any] = [
                "RequestType": requestType,
                "ManifestURL": manifestURL.absoluteString
            ]
            if !pinningCerts.isEmpty {
                dict["ManifestURLPinningCerts"] = pinningCerts
            }
            return dict

        case .installProfile(let payload):
            return [
                "RequestType": requestType,
                "Payload": payload
            ]

        case .removeProfile(let payloadIdentifier):
            return [
                "RequestType": requestType,
                "Identifier": payloadIdentifier
            ]
        }
    }
}

extension MDMCommand {

    /// Renders the command as the XML-format plist Apple's
    /// `mdmclient` expects in the body of a `/mdm/server` GET
    /// response. The shape is:
    ///
    /// ```
    /// <dict>
    ///     <key>CommandUUID</key>
    ///     <string>UUID</string>
    ///     <key>Command</key>
    ///     <dict>
    ///         <key>RequestType</key>
    ///         <string>...</string>
    ///         <!-- type-specific fields -->
    ///     </dict>
    /// </dict>
    /// ```
    public func wirePlist() throws -> Data {
        let envelope: [String: Any] = [
            "CommandUUID": commandUUID.uuidString,
            "Command": kind.commandDictionary()
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: envelope,
            format: .xml,
            options: 0
        )
    }
}
