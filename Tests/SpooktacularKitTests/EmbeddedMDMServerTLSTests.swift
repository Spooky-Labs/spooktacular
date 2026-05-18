import Foundation
import Security
import Testing
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// End-to-end TLS tests that mint a real server certificate
/// via ``MDMIdentityIssuer``, hand it to ``EmbeddedMDMServer``,
/// and exercise a TLS connection from `URLSession`. The client
/// delegate validates the server's cert chain against the same
/// root CA the issuer minted — i.e. the *production* trust
/// shape, not a "trust anything" shortcut.
///
/// Skips silently if `/usr/bin/openssl` isn't on this host.
@Suite("Embedded MDM server (TLS round-trip)")
struct EmbeddedMDMServerTLSTests {

    private func opensslAvailable() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/openssl")
    }

    // MARK: - Rig

    /// Holds the URLSession delegate so the session retains
    /// it for the duration of the call.
    private final class RootCATrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
        private let rootCert: SecCertificate

        init(rootCertDER: Data) throws {
            guard let cert = SecCertificateCreateWithData(nil, rootCertDER as CFData) else {
                throw NSError(domain: "RootCATrustDelegate", code: 1)
            }
            self.rootCert = cert
            super.init()
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // Tell Security to validate against our root CA
            // explicitly (no system roots, no recognized
            // anchors).
            let setAnchorStatus = SecTrustSetAnchorCertificates(trust, [rootCert] as CFArray)
            guard setAnchorStatus == errSecSuccess else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // For the self-signed CA → server cert chain to
            // validate, the server cert just needs a matching
            // SAN. SecTrustEvaluateWithError returns true on
            // a clean chain.
            var error: CFError?
            let ok = SecTrustEvaluateWithError(trust, &error)
            if ok {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private func makeIssuer() throws -> MDMIdentityIssuer {
        try MDMIdentityIssuer(
            storageDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("spook-mdm-tls-test-\(UUID())"),
            caValidityDays: 1,
            identityValidityDays: 1
        )
    }

    // MARK: - TLS handshake + checkin round-trip

    @Test("TLS server accepts a PUT /mdm/checkin when the client trusts the root CA")
    func tlsCheckinRoundTrip() async throws {
        try #require(opensslAvailable())
        let issuer = try makeIssuer()
        defer { try? FileManager.default.removeItem(at: issuer.storageDirectory) }

        // Mint a server cert with SAN=localhost so the
        // hostname in the URL matches the cert SAN.
        let serverIdentity = try await issuer.serverCertificate(
            forHost: "localhost",
            additionalHosts: ["127.0.0.1"]
        )
        let rootDER = try await issuer.rootCertificateDER()

        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(deviceStore: store, commandQueue: queue)

        let server = try EmbeddedMDMServer(
            host: "127.0.0.1",
            port: 0,
            handler: handler,
            serverIdentity: EmbeddedMDMServer.ServerIdentity(
                pkcs12Data: serverIdentity.pkcs12Data,
                password: serverIdentity.password
            )
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let port = try #require(await server.boundPort)
        #expect(await server.isTLSEnabled)

        // Use URLSession with the root CA pinned. URL uses
        // "localhost" so SAN validation succeeds.
        let delegate = try RootCATrustDelegate(rootCertDER: rootDER)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )

        let body = try PropertyListSerialization.data(
            fromPropertyList: [
                "MessageType": "Authenticate",
                "UDID": "00008103-AAAABBBBCCCCDDDD",
                "Topic": "com.apple.mgmt.External.\(UUID().uuidString)",
                "Model": "VirtualMac2,1",
                "OSVersion": "26.4.0"
            ] as [String: Any],
            format: .xml,
            options: 0
        )
        var req = URLRequest(url: URL(string: "https://localhost:\(port)/mdm/checkin")!)
        req.httpMethod = "PUT"
        req.httpBody = body
        req.setValue(
            "application/x-apple-aspen-mdm-checkin",
            forHTTPHeaderField: "Content-Type"
        )

        let (_, response) = try await session.data(for: req)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)

        // Side effect: device record landed in the store
        let record = try #require(await store.record(forUDID: "00008103-AAAABBBBCCCCDDDD"))
        #expect(record.model == "VirtualMac2,1")
    }

    // MARK: - SAN mismatch detection

    @Test("Client rejects the connection when the URL host doesn't match the server cert SAN")
    func tlsSANMismatchFails() async throws {
        try #require(opensslAvailable())
        let issuer = try makeIssuer()
        defer { try? FileManager.default.removeItem(at: issuer.storageDirectory) }

        // SAN only covers "localhost" — connect via 127.0.0.1
        // and expect chain validation to fail.
        let serverIdentity = try await issuer.serverCertificate(
            forHost: "localhost"
        )
        let rootDER = try await issuer.rootCertificateDER()

        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(deviceStore: store, commandQueue: queue)
        let server = try EmbeddedMDMServer(
            host: "127.0.0.1",
            port: 0,
            handler: handler,
            serverIdentity: EmbeddedMDMServer.ServerIdentity(
                pkcs12Data: serverIdentity.pkcs12Data,
                password: serverIdentity.password
            )
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)

        let delegate = try RootCATrustDelegate(rootCertDER: rootDER)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )

        // 127.0.0.1 doesn't match SAN=localhost
        var req = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/mdm/checkin")!)
        req.httpMethod = "PUT"
        req.httpBody = Data()

        await #expect(throws: (any Error).self) {
            _ = try await session.data(for: req)
        }
    }

    // MARK: - Bad password is caught at server init

    @Test("Wrong PKCS#12 password surfaces as EmbeddedMDMServerError.pkcs12ImportFailed at start()")
    func wrongPasswordRejected() async throws {
        try #require(opensslAvailable())
        let issuer = try makeIssuer()
        defer { try? FileManager.default.removeItem(at: issuer.storageDirectory) }

        let serverIdentity = try await issuer.serverCertificate(forHost: "localhost")
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(deviceStore: store, commandQueue: queue)
        let server = try EmbeddedMDMServer(
            host: "127.0.0.1",
            port: 0,
            handler: handler,
            serverIdentity: EmbeddedMDMServer.ServerIdentity(
                pkcs12Data: serverIdentity.pkcs12Data,
                password: "wrong"
            )
        )
        await #expect(throws: EmbeddedMDMServerError.self) {
            try await server.start()
        }
    }

    // MARK: - Non-TLS server still works

    @Test("isTLSEnabled is false when no serverIdentity is supplied (no regression)")
    func plainHTTPMode() async throws {
        let store = MDMDeviceStore()
        let queue = MDMCommandQueue()
        let handler = SpooktacularMDMHandler(deviceStore: store, commandQueue: queue)
        let server = try EmbeddedMDMServer(
            host: "127.0.0.1",
            port: 0,
            handler: handler
        )
        try await server.start()
        defer { Task { await server.stop() } }
        #expect(await server.isTLSEnabled == false)
        #expect(await server.boundPort != nil)
    }
}
