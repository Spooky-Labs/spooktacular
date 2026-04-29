import Foundation

/// A `.mobileconfig` payload that, when installed in a macOS VM,
/// enrolls that VM into Spooktacular's host-running MDM server.
///
/// ## Why we ship our own MDM
///
/// macOS's `mdmclient` is the only sanctioned, sandbox-free path
/// for the host to install a privileged LaunchDaemon, install
/// configuration profiles, run an `InstallApplication` command,
/// and push ad-hoc commands into a running guest — without an
/// in-guest admin password prompt every time. Apple's
/// `SMAppService.daemon` route is blocked for sandboxed apps that
/// register script-based daemons (macOS 14.4+ rule), and asking
/// the user to click an Installer wizard for every VM defeats
/// the EC2-Mac-fleet-automation value prop. An MDM server living
/// on the host, talking to its own VMs over the existing virtio
/// network, gets us back to "host pushes a command, VM obeys"
/// with no in-guest UI at all.
///
/// ## What this type is
///
/// A pure-Foundation DTO + plist renderer. No networking, no
/// crypto, no Keychain. Phase 1 of the MDM build (see
/// `Tests/.../MDMEnrollmentProfileTests.swift`). Later phases
/// add:
///
/// - **Phase 2**: per-VM identity cert generation, embedded into
///   this profile as a PKCS#12 payload preceding the MDM payload
///   (so `mdmclient` finds the cert under
///   `IdentityCertificateUUID` when it tries to authenticate).
/// - **Phase 3+**: HTTP server, command queue, poll loop.
///
/// ## Plist shape
///
/// The rendered output is a standard top-level Configuration
/// profile. `PayloadContent` holds an array of nested payloads;
/// the MDM payload (`com.apple.mdm`) is the one that triggers
/// `mdmclient` to start checking in to ``serverURL``.
///
/// ```
/// Configuration (top-level)
///   PayloadContent: [
///     <Identity cert payload — added in Phase 2>,
///     com.apple.mdm payload {
///       ServerURL: https://host.local:port/mdm/server
///       CheckInURL: https://host.local:port/mdm/checkin
///       Topic: <ephemeral, since we don't use APNs>
///       IdentityCertificateUUID: <matches the cert payload>
///       AccessRights: <bitmask, see Apple's MDM Protocol Ref>
///       SignMessage: true
///       CheckOutWhenRemoved: true
///       ServerCapabilities: [com.apple.mdm.per-user-connections]
///     }
///   ]
/// ```
public struct MDMEnrollmentProfile: Sendable, Equatable {

    // MARK: - Identity

    /// The VM this enrollment is scoped to. Used in payload
    /// identifiers so two VMs' profiles never collide if both
    /// are inspected in the same `profiles list` output.
    public let vmID: UUID

    /// Stable UUID for the top-level Configuration payload.
    /// Distinct from ``vmID`` because Apple wants UUIDs that
    /// are unique per *payload*, not per device — re-issuing a
    /// new enrollment profile for the same VM should mint a
    /// fresh `payloadUUID` so the old profile's reference
    /// becomes stale.
    public let payloadUUID: UUID

    /// Stable UUID for the inner `com.apple.mdm` payload. Same
    /// "unique per payload" rule as ``payloadUUID``.
    public let mdmPayloadUUID: UUID

    /// UUID of the identity-certificate payload that this MDM
    /// payload references via `IdentityCertificateUUID`. Phase
    /// 1 leaves the cert payload itself out (added in Phase 2);
    /// the value is still present here so the wire format is
    /// stable across phases.
    public let identityCertificatePayloadUUID: UUID

    // MARK: - MDM endpoint

    /// Where the guest's `mdmclient` POSTs idle-state +
    /// command-response messages. Lives on the host running
    /// Spooktacular; reachable from the VM via the existing
    /// virtio NIC (or, in a follow-up, vsock-bridged HTTP).
    public let serverURL: URL

    /// Where the guest's `mdmclient` POSTs `Authenticate`,
    /// `TokenUpdate`, and `CheckOut` messages. Conventionally
    /// the same host as ``serverURL`` on a different path —
    /// keeping them split lets us route to different handlers
    /// without parsing the message type twice.
    public let checkInURL: URL

    // MARK: - MDM topic

    /// The MDM `Topic` that ties the enrollment to a push
    /// certificate's identifier. We don't use APNs (the host
    /// can drive its own VMs directly via polling), so the
    /// topic is just a unique, well-formed string of the right
    /// shape — `mdmclient` validates the format but doesn't
    /// dial out to APNs unless `PushMagic` + a push token are
    /// also supplied. See ``poll-only-rationale`` in the plan
    /// doc for why this works.
    public var topic: String {
        // Apple's documented MDM topic shape:
        //   com.apple.mgmt.{External,Internal}.<UUID>
        // We pick `External` because that's what third-party
        // MDMs use; the UUID portion is derived from the VM ID
        // so two enrollments of the same VM are deduplicated
        // by topic if `mdmclient` ever short-circuits on it.
        "com.apple.mgmt.External.\(vmID.uuidString)"
    }

    // MARK: - Init

    /// Designated initializer. Callers in tests / manual flows
    /// should supply UUIDs explicitly so the rendered plist is
    /// deterministic. ``random(vmID:serverURL:checkInURL:)``
    /// covers the runtime case of "fresh enrollment for a new
    /// VM".
    public init(
        vmID: UUID,
        payloadUUID: UUID,
        mdmPayloadUUID: UUID,
        identityCertificatePayloadUUID: UUID,
        serverURL: URL,
        checkInURL: URL
    ) {
        self.vmID = vmID
        self.payloadUUID = payloadUUID
        self.mdmPayloadUUID = mdmPayloadUUID
        self.identityCertificatePayloadUUID = identityCertificatePayloadUUID
        self.serverURL = serverURL
        self.checkInURL = checkInURL
    }

    /// Mints a fresh profile for the given VM — three new
    /// random payload UUIDs, plus the supplied endpoints. The
    /// runtime VM-create flow uses this; tests bypass it for
    /// determinism.
    public static func random(
        vmID: UUID,
        serverURL: URL,
        checkInURL: URL
    ) -> MDMEnrollmentProfile {
        MDMEnrollmentProfile(
            vmID: vmID,
            payloadUUID: UUID(),
            mdmPayloadUUID: UUID(),
            identityCertificatePayloadUUID: UUID(),
            serverURL: serverURL,
            checkInURL: checkInURL
        )
    }

    // MARK: - Plist render

    /// Serializes the profile to an XML-format `.mobileconfig`
    /// payload suitable for `profiles install -path -type
    /// system` or for inclusion in a VM's first-boot disk
    /// injection.
    ///
    /// Output is XML (not binary) so it's human-inspectable and
    /// matches what Apple's `profiles` tool emits — important
    /// for parity with off-the-shelf MDM tooling and for our
    /// own debugging.
    public func mobileconfig() throws -> Data {
        let plist: [String: Any] = [
            "PayloadType": "Configuration",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.spookylabs.mdm.enrollment.\(vmID.uuidString.lowercased())",
            "PayloadUUID": payloadUUID.uuidString,
            "PayloadDisplayName": "Spooktacular MDM Enrollment",
            "PayloadDescription": "Enrolls this VM in the Spooktacular host's MDM service.",
            "PayloadOrganization": "Spooktacular",
            "PayloadScope": "System",
            // PayloadRemovalDisallowed=false — operator should
            // be able to `profiles remove` to detach a runaway
            // VM from MDM during incident response without
            // having to wipe the disk.
            "PayloadRemovalDisallowed": false,
            "PayloadContent": [
                mdmPayloadDictionary
            ]
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    /// The inner `com.apple.mdm` payload. Surfaced
    /// separately so Phase 2 can inject a sibling identity-cert
    /// payload (PKCS#12) into the same `PayloadContent` array
    /// without the renderer having to know about it.
    private var mdmPayloadDictionary: [String: Any] {
        [
            "PayloadType": "com.apple.mdm",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.spookylabs.mdm.\(vmID.uuidString.lowercased())",
            "PayloadUUID": mdmPayloadUUID.uuidString,
            "PayloadDisplayName": "Spooktacular MDM",
            "PayloadDescription": "Permits Spooktacular to install configuration profiles, deliver applications, and run user-data scripts on this VM.",
            "PayloadOrganization": "Spooktacular",

            "ServerURL": serverURL.absoluteString,
            "CheckInURL": checkInURL.absoluteString,
            "Topic": topic,
            "IdentityCertificateUUID": identityCertificatePayloadUUID.uuidString,

            // `mdmclient` signs every check-in / response
            // message with the identity cert's private key.
            // Without this we'd have to fall back to plaintext
            // POSTs — fine for local-only links but the wire
            // format would diverge from real Apple MDM, making
            // future integration with off-the-shelf MDM
            // libraries (e.g. NanoMDM) harder.
            "SignMessage": true,

            // Bitmask of the rights we're granting the MDM
            // server. 8191 = 0x1FFF = every documented right
            // through macOS 11 (InspectInstalledProfiles +
            // InstallApplications + RestartDevice + ...). The
            // exact bits are documented in Apple's MDM
            // Protocol Reference Table 5-1; we take the full
            // set because the host is fully trusted by the VM
            // (same security domain) and granting partial
            // rights only adds friction to future commands.
            "AccessRights": 8191,

            // True so the VM tells the MDM server when its
            // profile is removed — otherwise we'd have stale
            // device entries on the host accumulating across
            // VM tear-downs.
            "CheckOutWhenRemoved": true,

            // Lets us run per-user MDM operations in addition
            // to per-device ones — needed if we ever push
            // user-scoped config in addition to device-scoped.
            // Cheap to enable now since it's just a capability
            // hint.
            "ServerCapabilities": [
                "com.apple.mdm.per-user-connections"
            ],

            // We deliberately DON'T set `UseDevelopmentAPNS`
            // (default `false`) since we don't use APNs at all
            // — see the poll-only design in Phase 5.
        ] as [String: Any]
    }
}
