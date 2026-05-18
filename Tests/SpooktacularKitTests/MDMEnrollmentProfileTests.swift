import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-1 + Phase-2-shape contract tests for
/// `MDMEnrollmentProfile`. Locks down the wire shape Apple's
/// `mdmclient` expects under both signed (production) and
/// unsigned (dev-loopback) policies.
@Suite("MDM enrollment profile")
struct MDMEnrollmentProfileTests {

    // MARK: - Helpers

    private let vmID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let payloadUUID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let mdmPayloadUUID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let identityPayloadUUID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    private func makeProfile(
        policy: MDMEnrollmentProfile.SignaturePolicy,
        serverURL: URL = URL(string: "https://host.local:8443/mdm/server")!,
        checkInURL: URL = URL(string: "https://host.local:8443/mdm/checkin")!
    ) -> MDMEnrollmentProfile {
        MDMEnrollmentProfile(
            vmID: vmID,
            payloadUUID: payloadUUID,
            mdmPayloadUUID: mdmPayloadUUID,
            serverURL: serverURL,
            checkInURL: checkInURL,
            signaturePolicy: policy
        )
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            Issue.record("Top-level plist was not a dictionary")
            return [:]
        }
        return plist
    }

    private func mdmPayload(_ data: Data) throws -> [String: Any] {
        let plist = try decode(data)
        let content = try #require(plist["PayloadContent"] as? [[String: Any]])
        return try #require(content.first(where: { ($0["PayloadType"] as? String) == "com.apple.mdm" }))
    }

    // MARK: - Top-level Configuration shape

    @Test("Top-level payload has the keys macOS requires for a Configuration profile")
    func topLevelKeys() throws {
        let plist = try decode(makeProfile(policy: .unsigned).mobileconfig())
        #expect(plist["PayloadType"] as? String == "Configuration")
        #expect(plist["PayloadVersion"] as? Int == 1)
        #expect(plist["PayloadScope"] as? String == "System")
        #expect(plist["PayloadOrganization"] as? String == "Spooktacular")
        #expect(plist["PayloadRemovalDisallowed"] as? Bool == false)
        #expect(plist["PayloadUUID"] as? String == payloadUUID.uuidString)
        #expect(
            (plist["PayloadIdentifier"] as? String)?.starts(with: "com.spookylabs.mdm.enrollment.") == true
        )
    }

    // MARK: - Unsigned (dev) policy

    @Test("Unsigned policy renders only the MDM payload (no identity payload)")
    func unsignedPayloadCount() throws {
        let plist = try decode(makeProfile(policy: .unsigned).mobileconfig())
        let content = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["PayloadType"] as? String == "com.apple.mdm")
    }

    @Test("Unsigned policy sets SignMessage=false and omits IdentityCertificateUUID")
    func unsignedSignMessageFalse() throws {
        let mdm = try mdmPayload(makeProfile(policy: .unsigned).mobileconfig())
        #expect(mdm["SignMessage"] as? Bool == false)
        #expect(mdm["IdentityCertificateUUID"] == nil)
    }

    // MARK: - Signed (production) policy

    @Test("Signed policy renders identity payload + MDM payload, in that order")
    func signedPayloadOrder() throws {
        let identity = MDMEnrollmentProfile.IdentityCertificate(
            payloadUUID: identityPayloadUUID,
            pkcs12Data: Data("FAKE-P12".utf8),
            password: "password"
        )
        let plist = try decode(
            makeProfile(policy: .signed(identity: identity)).mobileconfig()
        )
        let content = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["PayloadType"] as? String == "com.apple.security.pkcs12")
        #expect(content[1]["PayloadType"] as? String == "com.apple.mdm")
    }

    @Test("Signed policy embeds the PKCS#12 bytes + password in the identity payload")
    func signedIdentityPayloadFields() throws {
        let p12 = Data([0x30, 0x82, 0x01, 0x00])
        let identity = MDMEnrollmentProfile.IdentityCertificate(
            payloadUUID: identityPayloadUUID,
            pkcs12Data: p12,
            password: "S3cret!"
        )
        let plist = try decode(
            makeProfile(policy: .signed(identity: identity)).mobileconfig()
        )
        let content = try #require(plist["PayloadContent"] as? [[String: Any]])
        let cert = content[0]
        #expect(cert["PayloadUUID"] as? String == identityPayloadUUID.uuidString)
        #expect(cert["PayloadContent"] as? Data == p12)
        #expect(cert["Password"] as? String == "S3cret!")
    }

    @Test("Signed policy MDM payload references identity by UUID + sets SignMessage=true")
    func signedMDMPayloadReferencesIdentity() throws {
        let identity = MDMEnrollmentProfile.IdentityCertificate(
            payloadUUID: identityPayloadUUID,
            pkcs12Data: Data(),
            password: ""
        )
        let mdm = try mdmPayload(
            makeProfile(policy: .signed(identity: identity)).mobileconfig()
        )
        #expect(mdm["SignMessage"] as? Bool == true)
        #expect(mdm["IdentityCertificateUUID"] as? String == identityPayloadUUID.uuidString)
    }

    // MARK: - MDM payload shared keys

    @Test("MDM payload carries ServerURL, CheckInURL, AccessRights, CheckOutWhenRemoved on both policies")
    func sharedMDMPayloadKeys() throws {
        for policy: MDMEnrollmentProfile.SignaturePolicy in [
            .unsigned,
            .signed(identity: .init(
                payloadUUID: identityPayloadUUID,
                pkcs12Data: Data(),
                password: ""
            ))
        ] {
            let mdm = try mdmPayload(makeProfile(policy: policy).mobileconfig())
            #expect(mdm["PayloadType"] as? String == "com.apple.mdm")
            #expect(mdm["ServerURL"] as? String == "https://host.local:8443/mdm/server")
            #expect(mdm["CheckInURL"] as? String == "https://host.local:8443/mdm/checkin")
            #expect(mdm["AccessRights"] as? Int == 8191)
            #expect(mdm["CheckOutWhenRemoved"] as? Bool == true)
            let caps = try #require(mdm["ServerCapabilities"] as? [String])
            #expect(caps.contains("com.apple.mdm.per-user-connections"))
        }
    }

    @Test("Topic uses Apple's documented com.apple.mgmt.External.<UUID> shape")
    func topicShape() throws {
        let mdm = try mdmPayload(makeProfile(policy: .unsigned).mobileconfig())
        let topic = try #require(mdm["Topic"] as? String)
        #expect(topic.hasPrefix("com.apple.mgmt.External."))
        let suffix = topic.replacingOccurrences(of: "com.apple.mgmt.External.", with: "")
        #expect(UUID(uuidString: suffix) != nil)
    }

    // MARK: - Determinism + factories

    @Test("Rendering twice with the same UUIDs produces byte-identical output")
    func renderingIsDeterministic() throws {
        let profile = makeProfile(policy: .unsigned)
        #expect(try profile.mobileconfig() == profile.mobileconfig())
    }

    @Test("random() default mints fresh UUIDs and defaults to .unsigned")
    func randomDefaultsUnsigned() {
        let url = URL(string: "https://x/y")!
        let profile = MDMEnrollmentProfile.random(
            vmID: UUID(),
            serverURL: url,
            checkInURL: url
        )
        if case .unsigned = profile.signaturePolicy {
            // ok
        } else {
            Issue.record("random() should default to .unsigned")
        }
    }

    @Test("random() can be invoked with explicit signed policy")
    func randomCanBeSigned() {
        let url = URL(string: "https://x/y")!
        let identity = MDMEnrollmentProfile.IdentityCertificate(
            payloadUUID: UUID(),
            pkcs12Data: Data([0x01]),
            password: "p"
        )
        let profile = MDMEnrollmentProfile.random(
            vmID: UUID(),
            serverURL: url,
            checkInURL: url,
            signaturePolicy: .signed(identity: identity)
        )
        guard case .signed(let i) = profile.signaturePolicy else {
            Issue.record("Expected .signed, got \(profile.signaturePolicy)")
            return
        }
        #expect(i == identity)
    }

    // MARK: - XML format

    @Test("Output is XML-format plist matching `profiles` tool output")
    func outputIsXMLFormat() throws {
        let data = try makeProfile(policy: .unsigned).mobileconfig()
        let prefix = String(data: data.prefix(64), encoding: .utf8) ?? ""
        #expect(prefix.contains("<?xml"))
        #expect(prefix.contains("<!DOCTYPE plist"))
    }
}
