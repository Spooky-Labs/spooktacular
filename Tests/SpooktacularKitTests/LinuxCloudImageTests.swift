import Testing
import Foundation
@testable import SpooktacularApplication

@Suite("LinuxCloudImage")
struct LinuxCloudImageTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test("fedora releases.json resolves to newest aarch64 Cloud_Base raw.xz")
    func fedora() throws {
        let url = try LinuxCloudImage.parseFedoraReleases(fixture("fedora-releases.json"))
        #expect(url.absoluteString.contains("aarch64"))
        #expect(url.absoluteString.hasSuffix(".raw.xz"))
        // The recorded fixture's newest aarch64 Cloud_Base release is 44 —
        // the parser must pick the numeric maximum, not list order.
        #expect(url.absoluteString.contains("-44"))
    }

    @Test("debian index yields release codenames, excluding sid and backports")
    func debianCodenames() throws {
        let names = try LinuxCloudImage.parseDebianCodenames(fixture("debian-cloud-index.html"))
        #expect(names.contains("trixie"))
        #expect(names.contains("bookworm"))
        #expect(!names.contains("sid"))
        #expect(!names.contains { $0.contains("backports") })
    }

    @Test("debian latest listing yields release number + raw arm64 filename")
    func debianListing() throws {
        let parsed = try #require(
            LinuxCloudImage.parseDebianLatestListing(fixture("debian-trixie-latest.html"))
        )
        #expect(parsed.release == 13)
        #expect(parsed.fileName == "debian-13-genericcloud-arm64.raw")
    }

    @Test("debian alias resolves via index + per-codename listings to the highest release")
    func debianResolve() async throws {
        let index = try fixture("debian-cloud-index.html")
        let listing = try fixture("debian-trixie-latest.html")
        let r = try await LinuxCloudImage.resolve("debian") { url in
            if url.absoluteString == "https://cloud.debian.org/images/cloud/" { return index }
            if url.absoluteString.contains("/trixie/latest/") { return listing }
            throw URLError(.fileDoesNotExist)   // every other codename: unreleased/no listing
        }
        #expect(r == .download(
            url: try #require(URL(string:
                "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.raw")),
            suggestedFileName: "debian-13-genericcloud-arm64.raw",
            xzCompressed: false
        ))
    }

    @Test("local .raw path resolves without fetch")
    func localRaw() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID()).raw")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try await LinuxCloudImage.resolve(tmp.path) { _ in Data() }
        #expect(r == .localFile(tmp.standardizedFileURL, xzCompressed: false))
    }

    @Test("local .raw.xz marks xzCompressed")
    func localXZ() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("img-\(UUID()).raw.xz")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = try await LinuxCloudImage.resolve(tmp.path) { _ in Data() }
        #expect(r == .localFile(tmp.standardizedFileURL, xzCompressed: true))
    }

    @Test("qcow2 rejected with conversion hint")
    func qcow2() async {
        await #expect(throws: LinuxCloudImageError.qcow2Unsupported("/tmp/foo.qcow2")) {
            _ = try await LinuxCloudImage.resolve("/tmp/foo.qcow2") { _ in Data() }
        }
    }

    @Test("xz round-trip via Compression framework")
    func xzRoundTrip() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID())")
        let src = base.appendingPathExtension("bin")
        let xz = base.appendingPathExtension("xz")
        let out = base.appendingPathExtension("out")
        defer { for f in [src, xz, out] { try? FileManager.default.removeItem(at: f) } }
        let payload = Data((0..<65536).map { UInt8($0 % 251) })
        try payload.write(to: src)
        try LinuxCloudImage.compressXZForTesting(at: src, to: xz)
        try LinuxCloudImage.decompressXZ(at: xz, to: out)
        #expect(try Data(contentsOf: out) == payload)
    }
}
