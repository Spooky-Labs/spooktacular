import Foundation
import Testing
@testable import SpooktacularApplication

/// Phase-7 unit tests for `MDMUserDataDispatcher`.
/// Uses a `FakePkgBuilder` so the test path doesn't need
/// `pkgbuild` / `productbuild` on the host.
@Suite("MDM user-data dispatcher")
struct MDMUserDataDispatcherTests {

    private let udid = "00008103-AAAABBBBCCCCDDDD"
    private let topic = "com.apple.mgmt.External.44444444-4444-4444-4444-444444444444"

    /// Hands back canned bytes so the dispatcher's plumbing
    /// can be tested without invoking the real productbuild.
    private struct FakePkgBuilder: MDMUserDataPkgBuilding {
        let pkgData: Data
        let bundleIdentifier: String
        func buildPkg(
            scriptBody: Data,
            scriptName: String
        ) async throws -> MDMUserDataBuiltPackage {
            MDMUserDataBuiltPackage(
                pkgData: pkgData,
                bundleIdentifier: bundleIdentifier
            )
        }
    }

    private struct ThrowingPkgBuilder: MDMUserDataPkgBuilding {
        struct Boom: Error, Equatable {}
        func buildPkg(scriptBody: Data, scriptName: String) async throws -> MDMUserDataBuiltPackage {
            throw Boom()
        }
    }

    private func makeRig(
        builder: any MDMUserDataPkgBuilding = FakePkgBuilder(
            pkgData: Data("PKG-BYTES".utf8),
            bundleIdentifier: "com.example.userdata.fake"
        )
    ) -> (MDMUserDataDispatcher, SpooktacularMDMHandler, MDMContentStore) {
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(deviceStore: store, commandQueue: queue)
        let content = MDMContentStore()
        let dispatcher = MDMUserDataDispatcher(
            handler: handler,
            contentStore: content,
            pkgBuilder: builder,
            baseURL: URL(string: "https://host.local:8443")!
        )
        return (dispatcher, handler, content)
    }

    private func enroll(_ handler: SpooktacularMDMHandler, udid: String) async {
        await handler.didReceiveAuthenticate(.init(
            udid: udid, topic: topic, model: nil, osVersion: nil
        ))
    }

    // MARK: - Dispatch happy path

    @Test("dispatch builds pkg, registers in content store, enqueues InstallEnterpriseApplication")
    func dispatchHappyPath() async throws {
        let (dispatcher, handler, content) = makeRig()
        await enroll(handler, udid: udid)

        let result = try await dispatcher.dispatch(
            scriptBody: Data("#!/bin/bash\necho hello\n".utf8),
            scriptName: "hello.sh",
            toUDID: udid
        )

        // Content store should have the pkg + manifest under
        // the dispatcher-minted ID.
        let storedPkg = try #require(await content.pkg(forID: result.contentStoreID))
        #expect(storedPkg == Data("PKG-BYTES".utf8))
        let storedManifest = try #require(await content.manifest(forID: result.contentStoreID))
        // Manifest is XML plist — at least confirm it has the
        // bundle-identifier the fake builder declared.
        let manifest = try #require(
            try PropertyListSerialization.propertyList(
                from: storedManifest, options: [], format: nil
            ) as? [String: Any]
        )
        let metadata = try #require(
            ((manifest["items"] as? [[String: Any]])?.first?["metadata"] as? [String: Any])
        )
        #expect(metadata["bundle-identifier"] as? String == "com.example.userdata.fake")

        // Manifest URL is derived from baseURL + content ID
        let expectedURL = URL(
            string: "https://host.local:8443/mdm/manifest/\(result.contentStoreID.uuidString)"
        )!
        #expect(result.manifestURL == expectedURL)

        // Asset URL inside the manifest should reference the
        // pkg endpoint at the SAME content ID
        let asset = try #require(
            ((manifest["items"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]])?.first
        )
        let pkgURLString = try #require(asset["url"] as? String)
        #expect(pkgURLString == "https://host.local:8443/mdm/pkg/\(result.contentStoreID.uuidString)")

        // Command was enqueued for this device
        let next = await handler.nextCommand(forUDID: udid)
        #expect(next?.commandUUID == result.commandUUID)
        if case .installEnterpriseApplication(let url, let pinned) = next?.kind {
            #expect(url == result.manifestURL)
            #expect(pinned.isEmpty)
        } else {
            Issue.record("Expected installEnterpriseApplication, got \(String(describing: next?.kind))")
        }
    }

    // MARK: - Forget purges content store

    @Test("forget removes the pkg + manifest from the content store")
    func forgetPurges() async throws {
        let (dispatcher, handler, content) = makeRig()
        await enroll(handler, udid: udid)

        let result = try await dispatcher.dispatch(
            scriptBody: Data("script".utf8),
            scriptName: "x.sh",
            toUDID: udid
        )
        #expect(await content.pkg(forID: result.contentStoreID) != nil)
        await dispatcher.forget(result)
        #expect(await content.pkg(forID: result.contentStoreID) == nil)
        #expect(await content.manifest(forID: result.contentStoreID) == nil)
    }

    // MARK: - Builder failure propagates

    @Test("Builder error propagates without enqueuing or registering anything")
    func builderFailurePropagates() async throws {
        let (dispatcher, handler, content) = makeRig(builder: ThrowingPkgBuilder())
        await enroll(handler, udid: udid)

        await #expect(throws: ThrowingPkgBuilder.Boom.self) {
            _ = try await dispatcher.dispatch(
                scriptBody: Data("x".utf8),
                scriptName: "x.sh",
                toUDID: udid
            )
        }
        // Content store untouched
        #expect(await content.count == 0)
        // No command enqueued
        #expect(await handler.nextCommand(forUDID: udid) == nil)
    }
}
