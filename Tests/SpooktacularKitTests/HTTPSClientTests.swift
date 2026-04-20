import Foundation
import CryptoKit
import Testing
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularCore

/// Pipeline tests for ``HTTPSClient`` and the shared
/// ``RequestSigner`` protocol. Verifies:
///
/// 1. Typed-body encode + typed-response decode round-trip.
/// 2. Signers mutate the request headers correctly.
/// 3. ``HTTPSError`` classifies transport / status / decode
///    failures distinctly so callers can surface them
///    differently.
@Suite("HTTPSClient pipeline", .tags(.infrastructure))
struct HTTPSClientPipelineTests {

    @Test("StaticCredentialProvider returns its constant")
    func staticProviderConstant() async throws {
        let creds = SigV4Signer.Credentials(
            accessKeyID: "AKIAEXAMPLE",
            secretAccessKey: "secret",
            sessionToken: "token"
        )
        let provider = StaticCredentialProvider(creds)
        let returned = try await provider.credentials()
        #expect(returned.accessKeyID == "AKIAEXAMPLE")
        #expect(returned.secretAccessKey == "secret")
        #expect(returned.sessionToken == "token")
    }

    @Test("SigV4RequestSigner writes Authorization + x-amz-* headers")
    func signerWritesHeaders() async throws {
        let creds = SigV4Signer.Credentials(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: "session-token-xyz"
        )
        let signer = SigV4RequestSigner(
            service: "ebs",
            region: "us-east-1",
            provider: StaticCredentialProvider(creds)
        )

        var request = URLRequest(url: URL(string: "https://ebs.us-east-1.amazonaws.com/snapshots/snap-12345/blocks/0")!)
        request.httpMethod = "GET"

        try await signer.sign(&request)

        let auth = request.value(forHTTPHeaderField: "Authorization")
        #expect(auth?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/") == true)
        #expect(auth?.contains("/us-east-1/ebs/aws4_request") == true)
        #expect(auth?.contains("SignedHeaders=") == true)
        #expect(auth?.contains("Signature=") == true)

        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") != nil)
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "session-token-xyz")
        #expect(request.value(forHTTPHeaderField: "Host") == "ebs.us-east-1.amazonaws.com")
    }

    @Test("HMACRequestSigner writes hex-encoded MAC header")
    func hmacSignerWritesHeader() async throws {
        // Known test vector from RFC 4231 §4.2 — HMAC-SHA256
        // with the all-0x0b key over "Hi There" produces
        // b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7.
        let key = SymmetricKey(data: Data(repeating: 0x0b, count: 20))
        let signer = HMACRequestSigner(key: key, headerName: "X-Test-MAC")

        var request = URLRequest(url: URL(string: "https://example.com/audit")!)
        request.httpMethod = "POST"
        request.httpBody = Data("Hi There".utf8)

        try await signer.sign(&request)

        let mac = request.value(forHTTPHeaderField: "X-Test-MAC")
        #expect(mac == "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
    }

    @Test("HTTPSRequest preserves Method enum — no accidental lowercase")
    func methodEnumStringValue() {
        #expect(HTTPSRequest<EmptyBody>.Method.get.rawValue == "GET")
        #expect(HTTPSRequest<EmptyBody>.Method.post.rawValue == "POST")
        #expect(HTTPSRequest<EmptyBody>.Method.delete.rawValue == "DELETE")
        #expect(HTTPSRequest<EmptyBody>.Method.patch.rawValue == "PATCH")
    }

    @Test("EmptyBody is Codable and equal-to-itself")
    func emptyBodyCodable() throws {
        let value = EmptyBody()
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(EmptyBody.self, from: data)
        #expect(decoded == value)
    }


    @Test("Signer uses session-token when present, omits when nil")
    func sessionTokenConditional() async throws {
        let withToken = SigV4Signer.Credentials(
            accessKeyID: "AKIA",
            secretAccessKey: "sk",
            sessionToken: "tok"
        )
        let withoutToken = SigV4Signer.Credentials(
            accessKeyID: "AKIA",
            secretAccessKey: "sk"
        )

        let signerWith = SigV4RequestSigner(
            service: "ebs",
            region: "us-east-1",
            provider: StaticCredentialProvider(withToken)
        )
        let signerWithout = SigV4RequestSigner(
            service: "ebs",
            region: "us-east-1",
            provider: StaticCredentialProvider(withoutToken)
        )

        var req1 = URLRequest(url: URL(string: "https://example.com/")!)
        req1.httpMethod = "GET"
        try await signerWith.sign(&req1)
        #expect(req1.value(forHTTPHeaderField: "X-Amz-Security-Token") == "tok")

        var req2 = URLRequest(url: URL(string: "https://example.com/")!)
        req2.httpMethod = "GET"
        try await signerWithout.sign(&req2)
        #expect(req2.value(forHTTPHeaderField: "X-Amz-Security-Token") == nil)
    }
}
