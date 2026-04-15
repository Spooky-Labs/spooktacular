import Testing
import Foundation
@testable import SpookCore
@testable import SpookApplication
@testable import SpookInfrastructureApple

@Suite("FederatedIdentity")
struct FederatedIdentityTests {
    @Test("FederatedIdentity actorIdentity combines issuer and subject")
    func actorIdentity() {
        let id = FederatedIdentity(issuer: "https://accounts.google.com", subject: "user-123")
        #expect(id.actorIdentity == "https://accounts.google.com/user-123")
    }

    @Test("Expired identity reports isExpired")
    func expiredIdentity() {
        let id = FederatedIdentity(issuer: "test", subject: "s", expiresAt: Date.distantPast)
        #expect(id.isExpired)
    }

    @Test("Non-expired identity reports not expired")
    func validIdentity() {
        let id = FederatedIdentity(issuer: "test", subject: "s", expiresAt: Date.distantFuture)
        #expect(!id.isExpired)
    }

    @Test("OIDCProviderConfig encodes and decodes")
    func configCodable() throws {
        let config = OIDCProviderConfig(issuerURL: "https://example.com", clientID: "client-1")
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(OIDCProviderConfig.self, from: data)
        #expect(decoded.issuerURL == "https://example.com")
        #expect(decoded.clientID == "client-1")
    }

    @Test("OIDCTokenVerifier rejects malformed tokens")
    func rejectsMalformed() async {
        let config = OIDCProviderConfig(issuerURL: "https://test.com", clientID: "c")
        let verifier = OIDCTokenVerifier(config: config, http: MockHTTPClient())
        await #expect(throws: OIDCError.self) {
            try await verifier.verify(token: "not-a-jwt")
        }
    }
}

/// Minimal mock for testing.
private struct MockHTTPClient: HTTPClient {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
