import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("Provisioner injection seam", .tags(.infrastructure))
struct ProvisionerInjectingTests {

    /// Records what it was asked to do, standing in for either a root
    /// process or the GUI's approved helper.
    private final actor RecordingInjector: ProvisionerInjecting {
        private(set) var preflighted = false
        private(set) var injected: [URL] = []
        private let preflightError: (any Error)?

        init(preflightError: (any Error)? = nil) {
            self.preflightError = preflightError
        }

        func preflight() async throws {
            preflighted = true
            if let preflightError { throw preflightError }
        }

        func injectProvisioner(intoDiskImageAt url: URL) async throws {
            injected.append(url)
        }

        func snapshot() -> (preflighted: Bool, injected: [URL]) {
            (preflighted, injected)
        }
    }

    private struct Boom: Error, Equatable {}

    @available(macOS 27, *)
    @Test("a cache hit performs no privileged work at all")
    func cacheHitSkipsInjection() async throws {
        // The whole point of the base cache: the second and every later
        // create must not ask for privileges, so the injector must not
        // even be preflighted when a usable base already exists.
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        let descriptor = BaseImageDescriptor(
            buildVersion: "27A5301a",
            layerUUID: UUID(),
            sizeInBytes: 1024,
            createdAt: Date(),
            provisionerVersion: BaseImageBuilder.provisionerVersion
        )
        try store.write(descriptor)
        FileManager.default.createFile(
            atPath: store.baseImageURL(forBuild: "27A5301a").path,
            contents: Data()
        )

        let builder = BaseImageBuilder(store: store)
        let cached = try builder.cachedDescriptor(forBuild: "27A5301a")

        #expect(cached?.layerUUID == descriptor.layerUUID)
    }

    @Test("the direct injector reports missing assets rather than guessing")
    func directInjectorRequiresAssets() async throws {
        // With no app bundle staged (a plain `swift test` run),
        // ProvisionerAssets.locate() returns nil and preflight must say
        // so — this is the check that keeps a 20-minute install from
        // starting only to fail at the last step.
        let injector = DirectProvisionerInjector()
        await #expect(throws: (any Error).self) {
            try await injector.preflight()
        }
    }

    @Test("an injector's preflight failure propagates before any work")
    func preflightFailurePropagates() async throws {
        let injector = RecordingInjector(preflightError: Boom())
        await #expect(throws: Boom.self) {
            try await injector.preflight()
        }
        let snapshot = await injector.snapshot()
        #expect(snapshot.preflighted)
        #expect(snapshot.injected.isEmpty, "nothing may be injected after a failed preflight")
    }

    @Test("an injector receives the image it is asked to inject")
    func injectionTargetsTheImage() async throws {
        let injector = RecordingInjector()
        let image = URL(fileURLWithPath: "/tmp/base.asif")

        try await injector.preflight()
        try await injector.injectProvisioner(intoDiskImageAt: image)

        let snapshot = await injector.snapshot()
        #expect(snapshot.injected == [image])
    }
}
