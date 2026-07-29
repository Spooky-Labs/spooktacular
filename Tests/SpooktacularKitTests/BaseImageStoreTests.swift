import Testing
import Foundation
@testable import SpooktacularInfrastructureApple

@Suite("BaseImageStore", .tags(.infrastructure))
struct BaseImageStoreTests {

    @Test("paths are namespaced per macOS build")
    func perBuildPaths() {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)

        #expect(store.directory(forBuild: "27A5301a").lastPathComponent == "27A5301a")
        #expect(store.baseImageURL(forBuild: "27A5301a").lastPathComponent == "base.asif")
        #expect(store.auxiliaryStorageURL(forBuild: "27A5301a").lastPathComponent == "auxiliary.bin")
        #expect(store.hardwareModelURL(forBuild: "27A5301a").lastPathComponent == "hardware-model.bin")
        #expect(store.descriptorURL(forBuild: "27A5301a").lastPathComponent == "base.json")
    }

    @Test("descriptor round-trips through disk")
    func descriptorRoundTrip() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        let descriptor = BaseImageDescriptor(
            buildVersion: "27A5301a",
            layerUUID: UUID(),
            sizeInBytes: 64 * 1024 * 1024 * 1024,
            createdAt: Date(),
            provisionerVersion: "1"
        )

        try store.write(descriptor)
        let loaded = try store.descriptor(forBuild: "27A5301a")

        #expect(loaded?.layerUUID == descriptor.layerUUID)
        #expect(loaded?.sizeInBytes == descriptor.sizeInBytes)
    }

    @Test("descriptor is nil when no base exists")
    func descriptorMissing() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        #expect(try store.descriptor(forBuild: "nope") == nil)
        #expect(store.hasBase(forBuild: "nope") == false)
    }

    @Test("hasBase requires both the descriptor and the image file")
    func hasBaseRequiresBoth() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        try store.write(BaseImageDescriptor(
            buildVersion: "27A5301a",
            layerUUID: UUID(),
            sizeInBytes: 1024,
            createdAt: Date(),
            provisionerVersion: "1"
        ))
        // Descriptor exists but base.asif does not.
        #expect(store.hasBase(forBuild: "27A5301a") == false)

        FileManager.default.createFile(
            atPath: store.baseImageURL(forBuild: "27A5301a").path,
            contents: Data()
        )
        #expect(store.hasBase(forBuild: "27A5301a") == true)
    }

    @Test("build lock serializes and returns the body's value")
    func buildLock() async throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        let value = try await store.withBuildLock(forBuild: "27A5301a") { 42 }
        #expect(value == 42)
        // The lock is released, so a second acquisition succeeds.
        let again = try await store.withBuildLock(forBuild: "27A5301a") { 43 }
        #expect(again == 43)
    }

    @Test("build lock survives an await inside its body")
    func buildLockHoldsAcrossSuspension() async throws {
        // The real body awaits a 20-minute installer. A POSIX file lock
        // is held by the process rather than the thread, so it must
        // remain valid across suspension points — if it didn't, two
        // concurrent creates could both run an install.
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)

        let value = try await store.withBuildLock(forBuild: "27A5301a") { () -> Int in
            try await Task.sleep(nanoseconds: 10_000_000)
            return 7
        }
        #expect(value == 7)

        // Still acquirable afterwards, so the lock was released.
        let again = try await store.withBuildLock(forBuild: "27A5301a") { 8 }
        #expect(again == 8)
    }

    @Test("build lock releases even when the body throws")
    func buildLockReleasesOnThrow() async throws {
        struct Boom: Error {}
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)

        await #expect(throws: Boom.self) {
            try await store.withBuildLock(forBuild: "27A5301a") { throw Boom() }
        }
        // Still acquirable afterwards.
        let value = try await store.withBuildLock(forBuild: "27A5301a") { 7 }
        #expect(value == 7)
    }

    @Test("existing third octets are discoverable for subnet allocation")
    func listsBuilds() throws {
        let temp = TempDirectory()
        let store = BaseImageStore(rootDirectory: temp.url)
        try store.write(BaseImageDescriptor(
            buildVersion: "27A5301a",
            layerUUID: UUID(),
            sizeInBytes: 1024,
            createdAt: Date(),
            provisionerVersion: "1"
        ))
        FileManager.default.createFile(
            atPath: store.baseImageURL(forBuild: "27A5301a").path,
            contents: Data()
        )
        #expect(store.availableBuilds() == ["27A5301a"])
    }
}
