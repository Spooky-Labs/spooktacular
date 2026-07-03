import Foundation
import CryptoKit
import Testing
@testable import SpooktacularInfrastructureApple

/// Coverage for ``HMACRequestSigner`` and the shared
/// ``RequestSigner`` protocol it conforms to.
@Suite("HMACRequestSigner", .tags(.infrastructure))
struct HMACRequestSignerTests {

    @Test("HMACRequestSigner writes hex-encoded MAC header")
    func hmacSignerWritesHeader() async throws {
        // Known test vector from RFC 4231 §4.2 — HMAC-SHA256
        // with the all-0x0b key over "Hi There" produces
        // b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7.
        let key = SymmetricKey(data: Data(repeating: 0x0b, count: 20))
        let signer = HMACRequestSigner(key: key, headerName: "X-Test-MAC")

        let url = try #require(URL(string: "https://example.com/audit"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("Hi There".utf8)

        try await signer.sign(&request)

        let mac = request.value(forHTTPHeaderField: "X-Test-MAC")
        #expect(mac == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }
}
