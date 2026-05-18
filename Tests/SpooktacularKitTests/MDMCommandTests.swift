import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-4 wire-format tests for `MDMCommand` (host→device)
/// and `MDMCommandResponse` (device→host). These pin the
/// plist shapes Apple's `mdmclient` actually checks at parse
/// time — if they break, real device traffic stops working.
@Suite("MDM command wire format")
struct MDMCommandTests {

    private let sampleCommandUUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!

    // MARK: - Helpers

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            Issue.record("Top-level plist was not a dictionary")
            return [:]
        }
        return plist
    }

    private func encodeResponse(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
    }

    // MARK: - InstallEnterpriseApplication

    @Test("InstallEnterpriseApplication renders ManifestURL inside the Command dict")
    func installEnterpriseApplicationManifestURL() throws {
        let manifestURL = URL(string: "https://host.local:8443/mdm/manifest/some-vm.plist")!
        let cmd = MDMCommand(
            commandUUID: sampleCommandUUID,
            kind: .installEnterpriseApplication(
                manifestURL: manifestURL,
                manifestURLPinningCerts: []
            )
        )
        let plist = try decode(cmd.wirePlist())

        #expect(plist["CommandUUID"] as? String == sampleCommandUUID.uuidString)
        let inner = try #require(plist["Command"] as? [String: Any])
        #expect(inner["RequestType"] as? String == "InstallEnterpriseApplication")
        #expect(inner["ManifestURL"] as? String == manifestURL.absoluteString)
        #expect(inner["ManifestURLPinningCerts"] == nil,
                "Empty pinning cert list should be omitted entirely")
    }

    @Test("InstallEnterpriseApplication includes pinning certs when supplied")
    func installEnterpriseApplicationPinningCerts() throws {
        let derCert1 = Data([0x30, 0x82, 0x01, 0x00])
        let derCert2 = Data([0x30, 0x82, 0x02, 0x00])
        let cmd = MDMCommand(
            commandUUID: sampleCommandUUID,
            kind: .installEnterpriseApplication(
                manifestURL: URL(string: "https://example/m.plist")!,
                manifestURLPinningCerts: [derCert1, derCert2]
            )
        )
        let plist = try decode(cmd.wirePlist())
        let inner = try #require(plist["Command"] as? [String: Any])
        let pinned = try #require(inner["ManifestURLPinningCerts"] as? [Data])
        #expect(pinned == [derCert1, derCert2])
    }

    // MARK: - InstallProfile

    @Test("InstallProfile carries the profile bytes inline as Payload")
    func installProfile() throws {
        let payload = Data("<plist>...</plist>".utf8)
        let cmd = MDMCommand(
            commandUUID: sampleCommandUUID,
            kind: .installProfile(payload: payload)
        )
        let plist = try decode(cmd.wirePlist())
        let inner = try #require(plist["Command"] as? [String: Any])
        #expect(inner["RequestType"] as? String == "InstallProfile")
        #expect(inner["Payload"] as? Data == payload)
    }

    // MARK: - RemoveProfile

    @Test("RemoveProfile carries the PayloadIdentifier under Identifier")
    func removeProfile() throws {
        let cmd = MDMCommand(
            commandUUID: sampleCommandUUID,
            kind: .removeProfile(payloadIdentifier: "com.spookylabs.tenant.acme.egress")
        )
        let plist = try decode(cmd.wirePlist())
        let inner = try #require(plist["Command"] as? [String: Any])
        #expect(inner["RequestType"] as? String == "RemoveProfile")
        #expect(inner["Identifier"] as? String == "com.spookylabs.tenant.acme.egress")
    }

    // MARK: - Determinism

    @Test("Re-encoding the same command twice yields identical output (XML plist is stable)")
    func encodingIsDeterministic() throws {
        let cmd = MDMCommand(
            commandUUID: sampleCommandUUID,
            kind: .removeProfile(payloadIdentifier: "com.example")
        )
        #expect(try cmd.wirePlist() == cmd.wirePlist())
    }

    // MARK: - RequestType mapping

    @Test("Each Kind maps to the documented Apple RequestType string")
    func requestTypeMapping() {
        let install = MDMCommand.Kind.installEnterpriseApplication(
            manifestURL: URL(string: "https://x")!,
            manifestURLPinningCerts: []
        )
        let profile = MDMCommand.Kind.installProfile(payload: Data())
        let remove = MDMCommand.Kind.removeProfile(payloadIdentifier: "id")

        #expect(install.requestType == "InstallEnterpriseApplication")
        #expect(profile.requestType == "InstallProfile")
        #expect(remove.requestType == "RemoveProfile")
    }
}

@Suite("MDM command response decoding")
struct MDMCommandResponseTests {

    private let cmdUUID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let udid = "00008103-001234567890ABCD"

    private func encode(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
    }

    // MARK: - Acknowledged

    @Test("Acknowledged response decodes status + UDID + CommandUUID")
    func acknowledged() throws {
        let body = try encode([
            "CommandUUID": cmdUUID.uuidString,
            "UDID": udid,
            "Status": "Acknowledged"
        ])
        let response = try MDMCommandResponse.decode(plistBody: body)
        #expect(response.status == .acknowledged)
        #expect(response.commandUUID == cmdUUID)
        #expect(response.udid == udid)
        #expect(response.errorChain.isEmpty)
    }

    // MARK: - NotNow

    @Test("NotNow response decodes without an error chain")
    func notNow() throws {
        let body = try encode([
            "CommandUUID": cmdUUID.uuidString,
            "UDID": udid,
            "Status": "NotNow"
        ])
        let response = try MDMCommandResponse.decode(plistBody: body)
        #expect(response.status == .notNow)
        #expect(response.errorChain.isEmpty)
    }

    // MARK: - Idle

    @Test("Idle response is accepted without a CommandUUID")
    func idle() throws {
        let body = try encode([
            "UDID": udid,
            "Status": "Idle"
        ])
        let response = try MDMCommandResponse.decode(plistBody: body)
        #expect(response.status == .idle)
        #expect(response.udid == udid)
    }

    // MARK: - Error chain

    @Test("Error response decodes the ErrorChain entries with code + domain + descriptions")
    func errorChain() throws {
        let body = try encode([
            "CommandUUID": cmdUUID.uuidString,
            "UDID": udid,
            "Status": "Error",
            "ErrorChain": [
                [
                    "ErrorCode": 12017,
                    "ErrorDomain": "MCInstallationErrorDomain",
                    "LocalizedDescription": "Profile installation failed.",
                    "USEnglishDescription": "Profile installation failed."
                ],
                [
                    "ErrorCode": 4001,
                    "ErrorDomain": "MDMErrorDomain"
                ]
            ]
        ])
        let response = try MDMCommandResponse.decode(plistBody: body)
        #expect(response.status == .error)
        #expect(response.errorChain.count == 2)

        let first = response.errorChain[0]
        #expect(first.code == 12017)
        #expect(first.domain == "MCInstallationErrorDomain")
        #expect(first.localizedDescription == "Profile installation failed.")
        #expect(first.usEnglishDescription == "Profile installation failed.")

        let second = response.errorChain[1]
        #expect(second.code == 4001)
        #expect(second.domain == "MDMErrorDomain")
        #expect(second.localizedDescription == nil)
        #expect(second.usEnglishDescription == nil)
    }

    // MARK: - Malformed

    @Test("Missing UDID throws .missingField(UDID)")
    func missingUDID() throws {
        let body = try encode([
            "CommandUUID": cmdUUID.uuidString,
            "Status": "Acknowledged"
        ])
        #expect {
            try MDMCommandResponse.decode(plistBody: body)
        } throws: { error in
            (error as? MDMCommandResponseDecodeError) == .missingField(field: "UDID")
        }
    }

    @Test("Unknown Status value throws .invalidStatus")
    func invalidStatus() throws {
        let body = try encode([
            "CommandUUID": cmdUUID.uuidString,
            "UDID": udid,
            "Status": "Bogus"
        ])
        #expect {
            try MDMCommandResponse.decode(plistBody: body)
        } throws: { error in
            (error as? MDMCommandResponseDecodeError) == .invalidStatus(value: "Bogus")
        }
    }

    @Test("Non-Idle response without CommandUUID throws .missingField(CommandUUID)")
    func nonIdleMissingCommandUUID() throws {
        let body = try encode([
            "UDID": udid,
            "Status": "Acknowledged"
        ])
        #expect {
            try MDMCommandResponse.decode(plistBody: body)
        } throws: { error in
            (error as? MDMCommandResponseDecodeError) == .missingField(field: "CommandUUID")
        }
    }

    @Test("Top-level array body throws .notADictionary")
    func notADictionary() throws {
        let body = try PropertyListSerialization.data(
            fromPropertyList: ["a", "b"] as [String],
            format: .xml,
            options: 0
        )
        #expect {
            try MDMCommandResponse.decode(plistBody: body)
        } throws: { error in
            (error as? MDMCommandResponseDecodeError) == .notADictionary
        }
    }
}
