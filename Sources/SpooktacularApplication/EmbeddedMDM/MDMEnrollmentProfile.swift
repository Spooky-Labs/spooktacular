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

    // MARK: - Signing policy

    /// Whether this enrollment delivers a per-VM identity
    /// certificate (production) or stays unsigned (dev mode).
    ///
    /// Production deployments should always use `.signed(...)`
    /// — `mdmclient` signs every check-in / response message
    /// with the identity cert's private key, so the host can
    /// verify the device hasn't been MITM'd. Without an
    /// identity cert, the host has to trust whoever connects
    /// — fine for HTTP-loopback dev traffic, not for
    /// distributed deployments.
    public enum SignaturePolicy: Sendable, Equatable {

        /// Dev / loopback testing only. Renders the profile
        /// with `SignMessage = false` and no
        /// `IdentityCertificateUUID`. `mdmclient` accepts the
        /// profile and enrolls without challenging the device's
        /// identity. The embedded MDM server's per-request mTLS
        /// is also bypassed (it's HTTP-only in this mode).
        ///
        /// We use this exclusively for protocol round-trip
        /// validation against a real `mdmclient` running in a
        /// VM on the same host, before Phase 2's CA work
        /// lands.
        case unsigned

        /// Production. Embeds a `com.apple.security.pkcs12`
        /// payload immediately before the `com.apple.mdm`
        /// payload, with `IdentityCertificateUUID` referring
        /// to its `PayloadUUID`. `mdmclient` extracts the
        /// PKCS#12, imports cert+key into the system keychain,
        /// and uses the cert for all subsequent message
        /// signing.
        case signed(identity: IdentityCertificate)
    }

    /// Per-VM identity certificate + key bundle. Phase 2's CA
    /// work produces these; the renderer here just embeds
    /// them as a PKCS#12 payload so the file format stays
    /// pinned even before Phase 2 lands.
    public struct IdentityCertificate: Sendable, Equatable {
        /// `PayloadUUID` for the `com.apple.security.pkcs12`
        /// payload — referenced by the MDM payload's
        /// `IdentityCertificateUUID`.
        public let payloadUUID: UUID

        /// DER-encoded PKCS#12 (.p12) blob containing the
        /// per-VM certificate + private key, encrypted under
        /// ``password``.
        public let pkcs12Data: Data

        /// Password protecting the PKCS#12. Embedded in plain
        /// text inside the configuration profile (which itself
        /// rests under the host's filesystem protections).
        /// Apple's standard practice for MDM enrollment
        /// profiles.
        public let password: String

        public init(payloadUUID: UUID, pkcs12Data: Data, password: String) {
            self.payloadUUID = payloadUUID
            self.pkcs12Data = pkcs12Data
            self.password = password
        }
    }

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

    /// Whether and how the rendered profile carries a per-VM
    /// identity certificate. See ``SignaturePolicy``.
    public let signaturePolicy: SignaturePolicy

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
    /// deterministic. ``random(vmID:serverURL:checkInURL:signaturePolicy:)``
    /// covers the runtime case of "fresh enrollment for a new
    /// VM".
    public init(
        vmID: UUID,
        payloadUUID: UUID,
        mdmPayloadUUID: UUID,
        serverURL: URL,
        checkInURL: URL,
        signaturePolicy: SignaturePolicy
    ) {
        self.vmID = vmID
        self.payloadUUID = payloadUUID
        self.mdmPayloadUUID = mdmPayloadUUID
        self.serverURL = serverURL
        self.checkInURL = checkInURL
        self.signaturePolicy = signaturePolicy
    }

    /// Mints a fresh profile for the given VM — two new
    /// random payload UUIDs, plus the supplied endpoints +
    /// signature policy. The runtime VM-create flow uses this;
    /// tests bypass it for determinism.
    public static func random(
        vmID: UUID,
        serverURL: URL,
        checkInURL: URL,
        signaturePolicy: SignaturePolicy = .unsigned
    ) -> MDMEnrollmentProfile {
        MDMEnrollmentProfile(
            vmID: vmID,
            payloadUUID: UUID(),
            mdmPayloadUUID: UUID(),
            serverURL: serverURL,
            checkInURL: checkInURL,
            signaturePolicy: signaturePolicy
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
    ///
    /// When ``signaturePolicy`` is `.signed`, the rendered
    /// profile carries an extra `com.apple.security.pkcs12`
    /// payload immediately before the MDM payload —
    /// `mdmclient` walks `PayloadContent` looking up the
    /// `IdentityCertificateUUID` and pulls the cert+key from
    /// that payload during enrollment.
    public func mobileconfig() throws -> Data {
        var content: [[String: Any]] = []
        if case .signed(let identity) = signaturePolicy {
            content.append(identityPayloadDictionary(identity))
        }
        content.append(mdmPayloadDictionary)

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
            "PayloadContent": content
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }

    /// The inner `com.apple.mdm` payload. Conditional keys:
    /// `IdentityCertificateUUID` + `SignMessage` only present
    /// when `signaturePolicy == .signed`.
    private var mdmPayloadDictionary: [String: Any] {
        var dict: [String: Any] = [
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

            // Bitmask of the rights we're granting the MDM
            // server. 8191 = 0x1FFF = every documented right
            // through macOS 11 (InspectInstalledProfiles +
            // InstallApplications + RestartDevice + ...). See
            // Apple's MDM Protocol Reference Table 5-1.
            "AccessRights": 8191,

            // True so the VM tells the MDM server when its
            // profile is removed — otherwise we'd have stale
            // device entries on the host accumulating across
            // VM tear-downs.
            "CheckOutWhenRemoved": true,

            // Lets us run per-user MDM operations in addition
            // to per-device ones.
            "ServerCapabilities": [
                "com.apple.mdm.per-user-connections"
            ]
        ]

        switch signaturePolicy {
        case .unsigned:
            // Dev-only: explicitly false so `mdmclient` doesn't
            // try to sign messages with a non-existent
            // identity. `IdentityCertificateUUID` is omitted
            // entirely.
            dict["SignMessage"] = false
        case .signed(let identity):
            dict["IdentityCertificateUUID"] = identity.payloadUUID.uuidString
            dict["SignMessage"] = true
        }

        return dict
    }

    /// PKCS#12 cert payload that precedes the MDM payload when
    /// ``signaturePolicy == .signed``. `mdmclient` resolves
    /// the MDM payload's `IdentityCertificateUUID` against
    /// this payload's `PayloadUUID`, extracts the cert+key,
    /// and uses them for outgoing message signatures.
    private func identityPayloadDictionary(
        _ identity: IdentityCertificate
    ) -> [String: Any] {
        [
            "PayloadType": "com.apple.security.pkcs12",
            "PayloadVersion": 1,
            "PayloadIdentifier": "com.spookylabs.mdm.identity.\(vmID.uuidString.lowercased())",
            "PayloadUUID": identity.payloadUUID.uuidString,
            "PayloadDisplayName": "Spooktacular MDM Identity",
            "PayloadDescription": "Per-VM identity certificate the device uses to sign MDM messages.",
            // Apple expects raw DER bytes under PayloadContent
            // for the pkcs12 payload, plus a Password field.
            "PayloadContent": identity.pkcs12Data,
            "Password": identity.password
        ]
    }
}
