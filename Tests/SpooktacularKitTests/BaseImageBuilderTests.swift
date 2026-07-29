import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("BaseImageBuilder", .tags(.infrastructure))
struct BaseImageBuilderTests {

    private func completeBase(
        in store: BaseImageStore,
        build: String,
        provisionerVersion: String
    ) throws -> BaseImageDescriptor {
        let descriptor = BaseImageDescriptor(
            buildVersion: build,
            layerUUID: UUID(),
            sizeInBytes: 1024,
            createdAt: Date(),
            provisionerVersion: provisionerVersion
        )
        try store.write(descriptor)
        FileManager.default.createFile(
            atPath: store.baseImageURL(forBuild: build).path,
            contents: Data()
        )
        return descriptor
    }

    @available(macOS 27, *)
    @Test("an existing base built by the current provisioner is reused")
    func reusesExistingBase() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        let descriptor = try completeBase(
            in: store,
            build: "27A5301a",
            provisionerVersion: BaseImageBuilder.provisionerVersion
        )

        let builder = BaseImageBuilder(store: store)
        #expect(try builder.cachedDescriptor(forBuild: "27A5301a")?.layerUUID == descriptor.layerUUID)
    }

    @available(macOS 27, *)
    @Test("a base built by a different provisioner version is not reused")
    func rejectsStaleProvisioner() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        _ = try completeBase(in: store, build: "27A5301a", provisionerVersion: "ancient")

        let builder = BaseImageBuilder(store: store)
        #expect(try builder.cachedDescriptor(forBuild: "27A5301a") == nil)
    }

    @available(macOS 27, *)
    @Test("an incomplete base is not reused")
    func rejectsIncompleteBase() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        // Descriptor only — no base.asif.
        try store.write(BaseImageDescriptor(
            buildVersion: "27A5301a",
            layerUUID: UUID(),
            sizeInBytes: 1024,
            createdAt: Date(),
            provisionerVersion: BaseImageBuilder.provisionerVersion
        ))

        let builder = BaseImageBuilder(store: store)
        #expect(try builder.cachedDescriptor(forBuild: "27A5301a") == nil)
    }

    @available(macOS 27, *)
    @Test("sealing clears the write bits so overlays cannot corrupt the base")
    func sealMakesReadOnly() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        let builder = BaseImageBuilder(store: store)
        let file = temp.file("base.asif")
        FileManager.default.createFile(atPath: file.path, contents: Data([0x00]))

        try builder.seal(at: file)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? Int)
        #expect(permissions & 0o222 == 0, "no write bits may remain set")
    }
}
