import Testing
import Foundation
import CryptoKit
@testable import SpooktacularInfrastructureApple

@Suite("RestoreImageManager", .tags(.infrastructure))
struct RestoreImageManagerTests {

    @Test("DownloadProgress.fraction is finite and clamped")
    func progressFraction() {
        let zero = DownloadProgress(bytesReceived: 0, bytesTotal: 0, resumed: false)
        #expect(zero.fraction == 0.0)

        let half = DownloadProgress(bytesReceived: 50, bytesTotal: 100, resumed: false)
        #expect(half.fraction == 0.5)

        let over = DownloadProgress(bytesReceived: 200, bytesTotal: 100, resumed: true)
        #expect(over.fraction == 1.0, "fraction must clamp at 1.0 when bytesReceived overshoots")

        let resumed = DownloadProgress(bytesReceived: 10, bytesTotal: 100, resumed: true)
        #expect(resumed.resumed == true)
    }

    @Test("sha256 digest matches CryptoKit reference for a known payload")
    func sha256Verification() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data("the quick brown fox jumps over the lazy dog".utf8)
        try payload.write(to: tmp)

        let reference = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }.joined()

        let manager = RestoreImageManager(cacheDirectory: tmp.deletingLastPathComponent())
        let digest = try manager.sha256(of: tmp)
        #expect(digest == reference)

        #expect(try manager.verifyFileHash(at: tmp, expected: digest) == true)
        #expect(try manager.verifyFileHash(at: tmp, expected: String(repeating: "0", count: 64)) == false)
    }

    @Test("RestoreImageError.downloadFailed carries message")
    func downloadFailedDescription() {
        let err = RestoreImageError.downloadFailed(message: "timeout after 120s")
        #expect(err.localizedDescription.contains("timeout after 120s"))
        #expect(err.recoverySuggestion?.contains("resume") == true)
    }
}
