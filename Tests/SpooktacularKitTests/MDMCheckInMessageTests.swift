import Foundation
import Testing
@testable import SpooktacularApplication

/// Round-trip tests for `MDMCheckInMessage` plist decoding.
/// Pinned to the wire shapes Apple's MDM Protocol Reference
/// documents for `Authenticate`, `TokenUpdate`, and `CheckOut`
/// — if these fail, real `mdmclient` traffic won't parse.
@Suite("MDM check-in message decoding")
struct MDMCheckInMessageTests {

    // MARK: - Helpers

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dict,
            format: .xml,
            options: 0
        )
    }

    private let sampleUDID = "00008103-001234567890ABCD"
    private let sampleTopic = "com.apple.mgmt.External.11111111-1111-1111-1111-111111111111"

    // MARK: - Authenticate

    @Test("Authenticate plist decodes to .authenticate with UDID, Topic, Model, OSVersion")
    func authenticate() throws {
        let body = try plist([
            "MessageType": "Authenticate",
            "UDID": sampleUDID,
            "Topic": sampleTopic,
            "Model": "VirtualMac2,1",
            "OSVersion": "26.4.0"
        ])
        let msg = try MDMCheckInMessage.decode(plistBody: body)
        guard case .authenticate(let a) = msg else {
            Issue.record("Wrong variant: \(msg)")
            return
        }
        #expect(a.udid == sampleUDID)
        #expect(a.topic == sampleTopic)
        #expect(a.model == "VirtualMac2,1")
        #expect(a.osVersion == "26.4.0")
    }

    @Test("Authenticate without UDID throws .missingRequiredField")
    func authenticateMissingUDID() throws {
        let body = try plist([
            "MessageType": "Authenticate",
            "Topic": sampleTopic
        ])
        #expect {
            try MDMCheckInMessage.decode(plistBody: body)
        } throws: { error in
            (error as? MDMCheckInDecodeError) == .missingRequiredField(
                messageType: "Authenticate",
                field: "UDID"
            )
        }
    }

    // MARK: - TokenUpdate

    @Test("TokenUpdate plist decodes to .tokenUpdate with push token and PushMagic")
    func tokenUpdate() throws {
        let pushTokenBytes = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let unlockTokenBytes = Data([0xCA, 0xFE])
        let body = try plist([
            "MessageType": "TokenUpdate",
            "UDID": sampleUDID,
            "Topic": sampleTopic,
            "Token": pushTokenBytes,
            "PushMagic": "ABCDEF-MAGIC-12345",
            "UnlockToken": unlockTokenBytes
        ])
        let msg = try MDMCheckInMessage.decode(plistBody: body)
        guard case .tokenUpdate(let t) = msg else {
            Issue.record("Wrong variant: \(msg)")
            return
        }
        #expect(t.udid == sampleUDID)
        #expect(t.topic == sampleTopic)
        #expect(t.pushToken == pushTokenBytes)
        #expect(t.pushMagic == "ABCDEF-MAGIC-12345")
        #expect(t.unlockToken == unlockTokenBytes)
    }

    @Test("TokenUpdate without push token still decodes (poll-only design tolerates absence)")
    func tokenUpdateNoPush() throws {
        let body = try plist([
            "MessageType": "TokenUpdate",
            "UDID": sampleUDID,
            "Topic": sampleTopic
        ])
        let msg = try MDMCheckInMessage.decode(plistBody: body)
        guard case .tokenUpdate(let t) = msg else {
            Issue.record("Wrong variant: \(msg)")
            return
        }
        #expect(t.pushToken == nil)
        #expect(t.pushMagic == nil)
        #expect(t.unlockToken == nil)
    }

    // MARK: - CheckOut

    @Test("CheckOut plist decodes to .checkOut")
    func checkOut() throws {
        let body = try plist([
            "MessageType": "CheckOut",
            "UDID": sampleUDID,
            "Topic": sampleTopic
        ])
        let msg = try MDMCheckInMessage.decode(plistBody: body)
        guard case .checkOut(let c) = msg else {
            Issue.record("Wrong variant: \(msg)")
            return
        }
        #expect(c.udid == sampleUDID)
        #expect(c.topic == sampleTopic)
    }

    // MARK: - Unsupported types

    @Test("Unknown MessageType lands in .unsupported (forward-compatibility)")
    func unsupportedMessageType() throws {
        let body = try plist([
            "MessageType": "DeclarativeManagement",
            "UDID": sampleUDID,
            "Topic": sampleTopic
        ])
        let msg = try MDMCheckInMessage.decode(plistBody: body)
        guard case .unsupported(let messageType, let udid) = msg else {
            Issue.record("Wrong variant: \(msg)")
            return
        }
        #expect(messageType == "DeclarativeManagement")
        #expect(udid == sampleUDID)
    }

    // MARK: - Malformed bodies

    @Test("Top-level non-dictionary plist throws .notADictionary")
    func notADictionary() throws {
        let body = try plist(["wrapped": "in dict to make plist serialize"]) // produces dict
        // Re-serialize as an array root to provoke the error:
        let arrayBody = try PropertyListSerialization.data(
            fromPropertyList: ["foo", "bar"] as [String],
            format: .xml,
            options: 0
        )
        _ = body  // satisfy unused warning if compiler nags
        #expect {
            try MDMCheckInMessage.decode(plistBody: arrayBody)
        } throws: { error in
            (error as? MDMCheckInDecodeError) == .notADictionary
        }
    }

    @Test("Plist without MessageType throws .missingMessageType")
    func missingMessageType() throws {
        let body = try plist([
            "UDID": sampleUDID,
            "Topic": sampleTopic
        ])
        #expect {
            try MDMCheckInMessage.decode(plistBody: body)
        } throws: { error in
            (error as? MDMCheckInDecodeError) == .missingMessageType
        }
    }

    // MARK: - UDID convenience

    @Test("udid convenience property exposes the UDID across all variants")
    func udidConvenience() throws {
        let auth = MDMCheckInMessage.authenticate(.init(
            udid: sampleUDID, topic: sampleTopic, model: nil, osVersion: nil
        ))
        #expect(auth.udid == sampleUDID)

        let token = MDMCheckInMessage.tokenUpdate(.init(
            udid: sampleUDID, topic: sampleTopic,
            pushToken: nil, pushMagic: nil, unlockToken: nil
        ))
        #expect(token.udid == sampleUDID)

        let checkout = MDMCheckInMessage.checkOut(.init(
            udid: sampleUDID, topic: sampleTopic
        ))
        #expect(checkout.udid == sampleUDID)

        let unsupported = MDMCheckInMessage.unsupported(
            messageType: "DeclarativeManagement",
            udid: sampleUDID
        )
        #expect(unsupported.udid == sampleUDID)
    }
}
