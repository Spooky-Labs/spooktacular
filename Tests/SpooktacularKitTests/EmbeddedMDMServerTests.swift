import Foundation
import Testing
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// End-to-end tests that exercise the embedded MDM server
/// over real HTTP on loopback. Each test boots a server with
/// a fresh handler+queue+store on an OS-assigned port,
/// drives it with `URLSession`, and asserts both the wire
/// response and the side effects on the in-memory state.
///
/// Skips if a port can't be bound (e.g. CI sandbox restrictions).
@Suite("Embedded MDM server (HTTP loopback)")
struct EmbeddedMDMServerTests {

    private let udid = "00008103-AAAABBBBCCCCDDDD"
    private let topic = "com.apple.mgmt.External.33333333-3333-3333-3333-333333333333"

    // MARK: - Test rig

    /// Per-test fixtures bundled together so each test starts
    /// with a fresh server + handler + clean state on an
    /// OS-assigned port.
    private struct Rig {
        let server: EmbeddedMDMServer
        let handler: SpooktacularMDMHandler
        let deviceStore: MDMDeviceStore
        let queue: MDMCommandQueue
        let baseURL: URL
    }

    private func makeRig() async throws -> Rig {
        let store = MDMDeviceStore()
        let cmdQueue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(
            deviceStore: store,
            commandQueue: cmdQueue
        )
        let server = try EmbeddedMDMServer(
            host: "127.0.0.1",
            port: 0, // OS-assigned
            handler: handler
        )
        try await server.start()
        let port = await server.boundPort
        guard let port else {
            throw EmbeddedMDMServerTestError.noBoundPort
        }
        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))
        return Rig(
            server: server,
            handler: handler,
            deviceStore: store,
            queue: cmdQueue,
            baseURL: baseURL
        )
    }

    private enum EmbeddedMDMServerTestError: Error {
        case noBoundPort
    }

    private func plist(_ dict: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0
        )
    }

    private func putPlist(
        _ data: Data,
        path: String,
        baseURL: URL
    ) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "PUT"
        req.httpBody = data
        req.setValue("application/x-apple-aspen-mdm-checkin", forHTTPHeaderField: "Content-Type")
        let (body, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        return (body, http)
    }

    // MARK: - Authenticate round-trip

    @Test("Authenticate plist over HTTP creates a record in the device store")
    func authenticateRoundTrip() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        let body = try plist([
            "MessageType": "Authenticate",
            "UDID": udid,
            "Topic": topic,
            "Model": "VirtualMac2,1",
            "OSVersion": "26.4.0"
        ])
        let (_, response) = try await putPlist(body, path: "/mdm/checkin", baseURL: rig.baseURL)
        #expect(response.statusCode == 200)

        let record = try #require(await rig.deviceStore.record(forUDID: udid))
        #expect(record.udid == udid)
        #expect(record.model == "VirtualMac2,1")
        #expect(record.checkedOut == false)
    }

    // MARK: - CheckOut

    @Test("CheckOut over HTTP flags the record + drains the queue")
    func checkOutFlow() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        // Pre-enroll
        await rig.handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: nil, osVersion: nil
        ))
        await rig.handler.enqueue(
            MDMCommand(kind: .removeProfile(payloadIdentifier: "stranded")),
            forUDID: udid
        )

        let body = try plist([
            "MessageType": "CheckOut",
            "UDID": udid,
            "Topic": topic
        ])
        let (_, response) = try await putPlist(body, path: "/mdm/checkin", baseURL: rig.baseURL)
        #expect(response.statusCode == 200)

        let record = try #require(await rig.deviceStore.record(forUDID: udid))
        #expect(record.checkedOut == true)
        #expect(await rig.queue.pending(forUDID: udid).isEmpty)
    }

    // MARK: - Idle poll → empty body

    @Test("Idle response on /mdm/server with empty queue returns 200 + empty body")
    func idlePollEmpty() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        await rig.handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: nil, osVersion: nil
        ))

        let idleBody = try plist([
            "Status": "Idle",
            "UDID": udid
        ])
        let (responseBody, response) = try await putPlist(idleBody, path: "/mdm/server", baseURL: rig.baseURL)
        #expect(response.statusCode == 200)
        #expect(responseBody.isEmpty)
    }

    // MARK: - Idle poll dispatches a queued command

    @Test("Idle poll with a queued command returns the command's wire plist")
    func idlePollDispatchesCommand() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        await rig.handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: nil, osVersion: nil
        ))

        let manifestURL = URL(string: "https://host.local/m.plist")!
        let cmd = MDMCommand(
            kind: .installEnterpriseApplication(
                manifestURL: manifestURL,
                manifestURLPinningCerts: []
            )
        )
        await rig.handler.enqueue(cmd, forUDID: udid)

        let idleBody = try plist([
            "Status": "Idle",
            "UDID": udid
        ])
        let (responseBody, response) = try await putPlist(
            idleBody, path: "/mdm/server", baseURL: rig.baseURL
        )
        #expect(response.statusCode == 200)
        #expect(!responseBody.isEmpty, "Expected the command plist in the body")

        // Verify the wire format
        let parsed = try PropertyListSerialization.propertyList(
            from: responseBody, options: [], format: nil
        ) as? [String: Any]
        let dict = try #require(parsed)
        #expect(dict["CommandUUID"] as? String == cmd.commandUUID.uuidString)
        let inner = try #require(dict["Command"] as? [String: Any])
        #expect(inner["RequestType"] as? String == "InstallEnterpriseApplication")
        #expect(inner["ManifestURL"] as? String == manifestURL.absoluteString)
    }

    // MARK: - Acknowledged response advances queue

    @Test("Acknowledged response over HTTP clears in-flight + queues advance")
    func ackAdvancesQueue() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        await rig.handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: nil, osVersion: nil
        ))

        let a = MDMCommand(kind: .removeProfile(payloadIdentifier: "a"))
        let b = MDMCommand(kind: .removeProfile(payloadIdentifier: "b"))
        await rig.handler.enqueue(a, forUDID: udid)
        await rig.handler.enqueue(b, forUDID: udid)

        // Idle → server returns a (in-flight)
        let idleBody = try plist([
            "Status": "Idle",
            "UDID": udid
        ])
        let (firstBody, first) = try await putPlist(idleBody, path: "/mdm/server", baseURL: rig.baseURL)
        #expect(first.statusCode == 200)
        #expect(!firstBody.isEmpty)

        // Ack a
        let ack = try plist([
            "Status": "Acknowledged",
            "UDID": udid,
            "CommandUUID": a.commandUUID.uuidString
        ])
        let (_, ackResp) = try await putPlist(ack, path: "/mdm/server", baseURL: rig.baseURL)
        #expect(ackResp.statusCode == 200)

        // The same /mdm/server PUT (ack) doubles as a poll —
        // the server SHOULD return b in its response body
        // because the queue advanced.

        // To verify b is now in flight, do a follow-up Idle:
        let (secondBody, second) = try await putPlist(idleBody, path: "/mdm/server", baseURL: rig.baseURL)
        #expect(second.statusCode == 200)
        let parsed = try PropertyListSerialization.propertyList(
            from: secondBody, options: [], format: nil
        ) as? [String: Any]
        let dict = try #require(parsed)
        #expect(dict["CommandUUID"] as? String == b.commandUUID.uuidString)
    }

    // MARK: - Routing

    @Test("Unknown path returns 404")
    func unknownPath() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        var req = URLRequest(url: rig.baseURL.appendingPathComponent("/whatever"))
        req.httpMethod = "PUT"
        req.httpBody = Data()
        let (_, response) = try await URLSession.shared.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 404)
    }

    @Test("Malformed plist body on /mdm/checkin returns 400")
    func malformedCheckIn() async throws {
        let rig = try await makeRig()
        defer { Task { await rig.server.stop() } }

        let (_, response) = try await putPlist(
            Data("not a plist".utf8),
            path: "/mdm/checkin",
            baseURL: rig.baseURL
        )
        #expect(response.statusCode == 400)
    }
}
