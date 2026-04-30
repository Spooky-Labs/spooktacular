import Foundation
import Testing
import CryptoKit
@testable import SpooktacularApplication

@Suite("MDM manifest builder")
struct MDMManifestBuilderTests {

    // MARK: - Helpers

    private func decode(_ data: Data) throws -> [String: Any] {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            Issue.record("Manifest plist not a dictionary")
            return [:]
        }
        return plist
    }

    // MARK: - Top-level shape

    @Test("Manifest has the items[0].assets + items[0].metadata Apple-shape skeleton")
    func skeletonShape() throws {
        let manifest = try MDMManifestBuilder.build(
            pkgData: Data("hello".utf8),
            pkgURL: URL(string: "https://h/p.pkg")!,
            bundleIdentifier: "com.example.userdata.001"
        )
        let plist = try decode(manifest)
        let items = try #require(plist["items"] as? [[String: Any]])
        #expect(items.count == 1)
        let item = items[0]
        let assets = try #require(item["assets"] as? [[String: Any]])
        #expect(assets.count == 1)
        let metadata = try #require(item["metadata"] as? [String: Any])
        #expect(metadata["bundle-identifier"] as? String == "com.example.userdata.001")
        #expect(metadata["kind"] as? String == "software")
    }

    @Test("Asset URL + chunk size + chunk MD5s round-trip into the plist")
    func assetFields() throws {
        let body = Data("a".utf8) + Data("b".utf8)  // 2 bytes
        let manifest = try MDMManifestBuilder.build(
            pkgData: body,
            pkgURL: URL(string: "https://host:8443/mdm/pkg/abc")!,
            bundleIdentifier: "com.example.userdata.002",
            chunkSize: 1
        )
        let plist = try decode(manifest)
        let asset = try #require(
            (plist["items"] as? [[String: Any]])?.first?["assets"] as? [[String: Any]]
        )[0]
        #expect(asset["kind"] as? String == "software-package")
        #expect(asset["url"] as? String == "https://host:8443/mdm/pkg/abc")
        #expect(asset["md5-size"] as? Int == 1)
        let md5s = try #require(asset["md5s"] as? [String])
        #expect(md5s.count == 2)
        // a → 0cc175b9c0f1b6a831c399e269772661
        // b → 92eb5ffee6ae2fec3ad71c777531578f
        #expect(md5s[0] == "0cc175b9c0f1b6a831c399e269772661")
        #expect(md5s[1] == "92eb5ffee6ae2fec3ad71c777531578f")
    }

    // MARK: - Chunking edge cases

    @Test("Single-chunk pkg produces a single MD5")
    func singleChunk() {
        let data = Data(repeating: 0xAB, count: 1024)
        let md5s = MDMManifestBuilder.chunkMD5s(of: data, chunkSize: 4096)
        #expect(md5s.count == 1)
        #expect(md5s[0].count == 32)
    }

    @Test("Exact-multiple chunk count produces N hashes")
    func exactMultiple() {
        let chunk = Data(repeating: 0x00, count: 100)
        var data = Data()
        for _ in 0..<5 { data.append(chunk) }  // 5 × 100 = 500 bytes
        let md5s = MDMManifestBuilder.chunkMD5s(of: data, chunkSize: 100)
        #expect(md5s.count == 5)
        // All chunks identical → all hashes identical
        #expect(Set(md5s).count == 1)
    }

    @Test("Last chunk shorter than chunkSize still hashes")
    func ragged() {
        let data = Data(repeating: 0x00, count: 250)
        let md5s = MDMManifestBuilder.chunkMD5s(of: data, chunkSize: 100)
        #expect(md5s.count == 3)  // 100 + 100 + 50
    }

    @Test("Empty data yields zero chunks")
    func emptyChunks() {
        #expect(MDMManifestBuilder.chunkMD5s(of: Data(), chunkSize: 1024).isEmpty)
    }

    @Test("Zero chunkSize defends with empty array (avoids divide-by-zero)")
    func zeroChunkSize() {
        #expect(MDMManifestBuilder.chunkMD5s(of: Data("hi".utf8), chunkSize: 0).isEmpty)
    }
}

@Suite("MDM content store")
struct MDMContentStoreTests {

    private final class FakeClock: @unchecked Sendable {
        private var current: Date = Date(timeIntervalSince1970: 1_700_000_000)
        func now() -> Date { current }
        func advance(by seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
        }
    }

    private func makeStore() -> (MDMContentStore, FakeClock) {
        let clock = FakeClock()
        return (MDMContentStore(now: { clock.now() }), clock)
    }

    @Test("register stores pkg + manifest under a fresh UUID")
    func registerRoundTrip() async {
        let (store, _) = makeStore()
        let pkg = Data("PKG".utf8)
        let manifest = Data("MANIFEST".utf8)
        let id = await store.register(
            pkgData: pkg,
            manifestData: manifest,
            bundleIdentifier: "com.example.userdata.x"
        )
        #expect(await store.pkg(forID: id) == pkg)
        #expect(await store.manifest(forID: id) == manifest)
        #expect(await store.count == 1)
    }

    @Test("remove drops the item; lookup returns nil")
    func removeDrops() async {
        let (store, _) = makeStore()
        let id = await store.register(
            pkgData: Data("p".utf8),
            manifestData: Data("m".utf8),
            bundleIdentifier: "x"
        )
        await store.remove(id)
        #expect(await store.pkg(forID: id) == nil)
        #expect(await store.manifest(forID: id) == nil)
        #expect(await store.count == 0)
    }

    @Test("Two register calls produce distinct IDs")
    func distinctIDs() async {
        let (store, _) = makeStore()
        let a = await store.register(pkgData: Data(), manifestData: Data(), bundleIdentifier: "a")
        let b = await store.register(pkgData: Data(), manifestData: Data(), bundleIdentifier: "b")
        #expect(a != b)
        #expect(await store.count == 2)
    }

    @Test("createdAt is set from the injected clock")
    func createdAt() async {
        let (store, clock) = makeStore()
        let id = await store.register(
            pkgData: Data(),
            manifestData: Data(),
            bundleIdentifier: "x"
        )
        let item = await store.item(forID: id)
        #expect(item?.createdAt == clock.now())
    }
}
