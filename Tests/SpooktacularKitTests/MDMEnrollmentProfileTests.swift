import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-1 contract tests for `MDMEnrollmentProfile`.
///
/// These are pure-Foundation tests of the plist render — no
/// networking, no `mdmclient` involved. They lock down the wire
/// shape so subsequent phases (CA / HTTP server / poll loop) can
/// rely on the keys/values being where they're supposed to be.
@Suite("MDM enrollment profile")
struct MDMEnrollmentProfileTests {

    // MARK: - Helpers

    private func makeProfile(
        vmID: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        serverURL: URL = URL(string: "https://host.local:8443/mdm/server")!,
        checkInURL: URL = URL(string: "https://host.local:8443/mdm/checkin")!
    ) -> MDMEnrollmentProfile {
        MDMEnrollmentProfile(
            vmID: vmID,
            payloadUUID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            mdmPayloadUUID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            identityCertificatePayloadUUID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            serverURL: serverURL,
            checkInURL: checkInURL
        )
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any] else {
            Issue.record("Top-level plist was not a dictionary")
            return [:]
        }
        return plist
    }

    // MARK: - Top-level Configuration shape

    @Test("Top-level payload has the keys macOS requires for a Configuration profile")
    func topLevelKeys() throws {
        let profile = makeProfile()
        let plist = try decode(profile.mobileconfig())

        #expect(plist["PayloadType"] as? String == "Configuration")
        #expect(plist["PayloadVersion"] as? Int == 1)
        #expect(plist["PayloadScope"] as? String == "System")
        #expect(plist["PayloadOrganization"] as? String == "Spooktacular")
        #expect(plist["PayloadRemovalDisallowed"] as? Bool == false)
        #expect(plist["PayloadUUID"] as? String == "22222222-2222-2222-2222-222222222222")
        #expect(
            (plist["PayloadIdentifier"] as? String)?.starts(with: "com.spookylabs.mdm.enrollment.") == true
        )
    }

    @Test("PayloadContent contains exactly one MDM payload (Phase 1 — cert payload added in Phase 2)")
    func payloadContentContainsOnlyMDMPayload() throws {
        let profile = makeProfile()
        let plist = try decode(profile.mobileconfig())

        let content = try #require(plist["PayloadContent"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.first?["PayloadType"] as? String == "com.apple.mdm")
    }

    // MARK: - MDM payload contents

    @Test("MDM payload carries the URLs, identity reference, and access rights mdmclient checks")
    func mdmPayloadKeys() throws {
        let profile = makeProfile()
        let plist = try decode(profile.mobileconfig())
        let mdm = try #require(
            (plist["PayloadContent"] as? [[String: Any]])?.first
        )

        #expect(mdm["PayloadType"] as? String == "com.apple.mdm")
        #expect(mdm["PayloadVersion"] as? Int == 1)
        #expect(mdm["PayloadUUID"] as? String == "33333333-3333-3333-3333-333333333333")
        #expect(mdm["ServerURL"] as? String == "https://host.local:8443/mdm/server")
        #expect(mdm["CheckInURL"] as? String == "https://host.local:8443/mdm/checkin")
        #expect(mdm["IdentityCertificateUUID"] as? String == "44444444-4444-4444-4444-444444444444")
        #expect(mdm["SignMessage"] as? Bool == true)
        #expect(mdm["CheckOutWhenRemoved"] as? Bool == true)
        #expect(mdm["AccessRights"] as? Int == 8191)
    }

    @Test("Topic uses the documented Apple MDM topic shape so mdmclient accepts the format")
    func topicShape() throws {
        let profile = makeProfile()
        let plist = try decode(profile.mobileconfig())
        let mdm = try #require(
            (plist["PayloadContent"] as? [[String: Any]])?.first
        )
        let topic = try #require(mdm["Topic"] as? String)

        #expect(topic.hasPrefix("com.apple.mgmt.External."))
        let suffix = topic.replacingOccurrences(of: "com.apple.mgmt.External.", with: "")
        #expect(UUID(uuidString: suffix) != nil)
    }

    @Test("ServerCapabilities advertises per-user connections so we can scope future commands")
    func serverCapabilities() throws {
        let profile = makeProfile()
        let plist = try decode(profile.mobileconfig())
        let mdm = try #require(
            (plist["PayloadContent"] as? [[String: Any]])?.first
        )
        let caps = try #require(mdm["ServerCapabilities"] as? [String])
        #expect(caps.contains("com.apple.mdm.per-user-connections"))
    }

    // MARK: - Determinism + uniqueness

    @Test("Rendering twice with the same UUIDs produces byte-identical output")
    func renderingIsDeterministic() throws {
        let profile = makeProfile()
        let first = try profile.mobileconfig()
        let second = try profile.mobileconfig()
        #expect(first == second)
    }

    @Test("Each random() call mints fresh payload UUIDs but keeps the supplied vmID")
    func randomMintsFreshUUIDs() {
        let vmID = UUID()
        let serverURL = URL(string: "https://example.local/mdm/server")!
        let checkInURL = URL(string: "https://example.local/mdm/checkin")!

        let a = MDMEnrollmentProfile.random(
            vmID: vmID,
            serverURL: serverURL,
            checkInURL: checkInURL
        )
        let b = MDMEnrollmentProfile.random(
            vmID: vmID,
            serverURL: serverURL,
            checkInURL: checkInURL
        )

        #expect(a.vmID == b.vmID)
        #expect(a.payloadUUID != b.payloadUUID)
        #expect(a.mdmPayloadUUID != b.mdmPayloadUUID)
        #expect(a.identityCertificatePayloadUUID != b.identityCertificatePayloadUUID)
    }

    // MARK: - XML format (vs binary)

    @Test("Output is XML-format plist so it's human-inspectable and matches `profiles` tool output")
    func outputIsXMLFormat() throws {
        let data = try makeProfile().mobileconfig()
        let prefix = String(data: data.prefix(64), encoding: .utf8) ?? ""
        #expect(prefix.contains("<?xml"))
        #expect(prefix.contains("<!DOCTYPE plist"))
    }
}
