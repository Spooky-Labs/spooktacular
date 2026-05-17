import Foundation
import Testing
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// End-to-end test for the full `spook mdm run` pipeline,
/// emulating what `spook mdm serve` does on every drain
/// cycle:
///
/// 1. Operator (CLI process A) writes a request to the
///    outbox.
/// 2. Serve (process B) calls `outbox.drain { req in ... }`.
/// 3. The drain handler invokes `MDMUserDataDispatcher` which
///    runs pkgBuilder, registers content, and enqueues an
///    `InstallEnterpriseApplication` command.
/// 4. The command lands in the device's queue, ready for
///    delivery on the next /mdm/server poll.
///
/// Uses a fake pkg builder so the test doesn't need
/// `/usr/bin/pkgbuild` (kept independent of the real-
/// openssl-dependent issuer tests).
@Suite("MDM `run` pipeline (outbox → drain → dispatcher → queue)")
struct MDMRunPipelineTests {

    private let udid = "00008103-FAFAFAFAFAFAFAFA"
    private let topic = "com.apple.mgmt.External.\(UUID().uuidString)"

    private struct StubBuilder: MDMUserDataPkgBuilding {
        func buildPkg(scriptBody: Data, scriptName: String) async throws -> MDMUserDataBuiltPackage {
            MDMUserDataBuiltPackage(
                pkgData: Data("FAKE-PKG-\(scriptName)".utf8),
                bundleIdentifier: "com.example.userdata.stub-\(UUID().uuidString.lowercased())"
            )
        }
    }

    @Test("Outbox request flows through drain → dispatcher → handler queue end-to-end")
    func endToEndRunPipeline() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-run-pipeline-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Build the full host-side stack
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(deviceStore: store, commandQueue: queue)
        let content = MDMContentStore()
        let dispatcher = MDMUserDataDispatcher(
            handler: handler,
            contentStore: content,
            pkgBuilder: StubBuilder(),
            baseURL: URL(string: "https://host.local:8443")!
        )
        let outbox = MDMDispatchOutbox(directory: dir.appendingPathComponent("outbox"))

        // Pretend the VM enrolled — the dispatcher itself
        // doesn't gate on enrollment, but the CLI does. To
        // mirror reality, register the device.
        await handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: "VM", osVersion: "26.0"
        ))

        // 2. CLI side: submit a request
        let scriptBody = Data("#!/bin/bash\necho hello".utf8)
        let request = MDMDispatchOutbox.Request(
            udid: udid,
            scriptName: "smoke.sh",
            scriptBody: scriptBody
        )
        let submitted = try await outbox.submit(request)
        #expect(await outbox.pendingCount() == 1)

        // 3. Serve side: drain ONCE (as the polling loop
        // does every 2s)
        await outbox.drain { req in
            guard let body = req.scriptBody else {
                return .failed(reason: "Malformed body")
            }
            do {
                _ = try await dispatcher.dispatch(
                    scriptBody: body,
                    scriptName: req.scriptName,
                    toUDID: req.udid
                )
                return .delivered
            } catch {
                return .failed(reason: error.localizedDescription)
            }
        }

        // 4. Outbox is drained
        #expect(await outbox.pendingCount() == 0)

        // 5. Command sits in the handler's queue ready for
        //    the device's next poll
        let next = await handler.nextCommand(forUDID: udid)
        let command = try #require(next)
        guard case .installEnterpriseApplication(let manifestURL, _) = command.kind else {
            Issue.record("Expected InstallEnterpriseApplication; got \(command.kind)")
            return
        }
        // Manifest URL points at our embedded server's
        // manifest endpoint with the content-store ID baked
        // in, so a real mdmclient would dereference it.
        #expect(manifestURL.absoluteString.contains("/mdm/manifest/"))

        // 6. Content store has the pkg + manifest under the
        //    same ID the manifest URL embeds
        let pathParts = manifestURL.pathComponents
        let lastComponent = try #require(pathParts.last)
        let contentID = try #require(UUID(uuidString: lastComponent))
        #expect(await content.pkg(forID: contentID) == Data("FAKE-PKG-smoke.sh".utf8))

        // Sanity: the submitted commandUUID was preserved as
        // it threaded the outbox; the dispatcher mints its
        // own commandUUID per dispatch (decoupled from the
        // outbox's), so we don't assert equality there. The
        // outbox UUID is preserved in audit logs.
        _ = submitted
    }
}
