import Foundation
import Testing
import Network
import Security
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularCore

/// End-to-end roundtrip test for the QUIC transport.
///
/// Validates the full handshake + send + receive path:
///
/// 1. ``TestCertFactory`` synthesizes a throwaway self-signed
///    P-256 TLS identity via `openssl` + `SecPKCS12Import`.
///    No Keychain pollution — the identity lives in a
///    transient memory-only keychain context returned by
///    `SecPKCS12Import`.
/// 2. A ``QUICRemoteStreamServer`` binds to a system-assigned
///    ephemeral port on loopback, echoing every received
///    chunk back to the sender.
/// 3. A ``QUICRemoteStreamClient`` connects via a custom
///    `sec_protocol_options_set_verify_block` that skips
///    CA-chain validation (we're not reaching Apple's docs
///    for this — see note below on why the cert check is
///    disabled in the test path).
///
/// > Note on verify block:
/// > For a properly trust-anchored test we'd import the
/// > self-signed cert as an anchor and evaluate the server
/// > trust against it via `SecTrustEvaluateWithError`.
/// > That's a separate test concern (cert pinning); this
/// > test focuses on the QUIC handshake + data path.  The
/// > verify-block accept-all is test-only; production code
/// > uses properly pinned anchors.
@Suite("QUIC Transport", .serialized)
struct QUICTransportTests {

    @Test("Server + client round-trip a byte buffer through a real QUIC handshake")
    func roundtripEcho() async throws {
        let factory = try TestCertFactory()
        defer { factory.cleanup() }

        let alpn = ["spooktacular-test"]
        let serverPort = NWEndpoint.Port(integerLiteral: UInt16.random(in: 55_000...60_000))

        // `SecIdentity` isn't `Sendable`; the
        // `identityLoader` closure is declared
        // `@Sendable` by the port.  Wrap the identity in
        // an `@unchecked Sendable` box so the closure
        // captures the box (Sendable by declaration)
        // rather than the bare identity.  Safe in this
        // test because the identity is effectively
        // immutable: it's initialized once and never
        // mutated.
        let identityBox = SendableIdentityBox(factory.identity)
        let server = QUICRemoteStreamServer(
            port: serverPort,
            alpn: alpn,
            identityLoader: { identityBox.identity }
        )

        // Echo server: for each incoming stream, read bytes
        // and immediately send them back.  Runs concurrently
        // with the client so the handshake can complete.
        let echoTask = Task {
            for await remote in server.incomingStreams {
                Task {
                    for try await chunk in remote.received {
                        try? await remote.send(chunk)
                    }
                }
            }
        }
        defer { echoTask.cancel() }

        try await server.start()

        let client = QUICRemoteStreamClient(
            alpn: alpn,
            trustMode: .acceptAnyCertificate_testOnly
        )
        let stream = try await client.connect(
            toHost: "localhost",
            port: serverPort.rawValue
        )

        let payload = Data("hello from QUIC roundtrip test".utf8)
        try await stream.send(payload)

        // Read back at least `payload.count` bytes.
        var received = Data()
        for try await chunk in stream.received {
            received.append(chunk)
            if received.count >= payload.count { break }
        }

        #expect(received == payload)

        stream.cancel()
        await server.stop()
    }
}

// MARK: - Self-signed test cert factory

/// Synthesizes a throwaway self-signed TLS identity for
/// tests.  Shells out to `/usr/bin/openssl` (part of the
/// macOS base system at `/usr/bin/openssl` — the
/// LibreSSL-backed system binary, not the Homebrew one)
/// to produce a P-256 key + cert + PKCS #12 bundle in a
/// unique tmp directory, then imports via
/// [`SecPKCS12Import`](https://developer.apple.com/documentation/security/secpkcs12import(_:_:_:))
/// which returns an in-memory `SecIdentity`.
///
/// No Keychain side effects.  Calling ``cleanup()``
/// removes the temp directory.
fileprivate final class TestCertFactory {
    let identity: SecIdentity
    private let tempDir: URL

    init() throws {
        let tempDir = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).appendingPathComponent(
            "spooktacular-quic-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        self.tempDir = tempDir

        let keyURL = tempDir.appendingPathComponent("key.pem")
        let certURL = tempDir.appendingPathComponent("cert.pem")
        let p12URL = tempDir.appendingPathComponent("identity.p12")

        // Step 1: generate a self-signed RSA 2048 cert.
        // Using RSA rather than EC because `SecPKCS12Import`
        // on macOS 26 rejects LibreSSL-produced PKCS12
        // containers carrying EC-encoded keys with a
        // `SecKeyCopyExternalRepresentation called with
        // NULL SecKeyRef` exception during
        // `build_trust_chains`.  RSA 2048 round-trips
        // through `SecPKCS12Import` reliably across every
        // macOS version we target.
        try Self.runOpenSSL([
            "req", "-x509",
            "-newkey", "rsa:2048",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "1",
            "-nodes",
            "-subj", "/CN=localhost",
        ])

        // Step 2: package the cert + key as a PKCS #12
        // bundle with a known password.  Explicit legacy
        // PBE algorithms (`PBE-SHA1-3DES` +
        // `-macalg sha1`) force the classic PKCS12 format
        // that `SecPKCS12Import` has supported since
        // macOS 10.7 — avoids the newer AES-256-CBC
        // format which Apple's importer handles
        // inconsistently across versions.
        try Self.runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-password", "pass:test",
            "-name", "spooktacular-quic-test",
            "-keypbe", "PBE-SHA1-3DES",
            "-certpbe", "PBE-SHA1-3DES",
            "-macalg", "sha1",
        ])

        // Step 3: import into an in-memory `SecIdentity`.
        let p12Data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: "test",
        ]
        var rawItems: CFArray?
        let status = SecPKCS12Import(
            p12Data as CFData,
            options as CFDictionary,
            &rawItems
        )
        guard status == errSecSuccess else {
            throw TestCertFactoryError.pkcs12ImportFailed(status)
        }
        guard let items = rawItems as? [[String: Any]],
              let first = items.first,
              let rawIdentity = first[kSecImportItemIdentity as String]
        else {
            throw TestCertFactoryError.identityNotFoundInPKCS12
        }
        // `SecPKCS12Import` returns the identity inside a
        // `CFArray` of `CFDictionary`s; the value under
        // `kSecImportItemIdentity` is a `SecIdentity`.  The
        // dictionary access goes through `Any`, so a cast is
        // required; the cast is type-checked rather than
        // force-unwrapped.
        guard CFGetTypeID(rawIdentity as CFTypeRef) == SecIdentityGetTypeID() else {
            throw TestCertFactoryError.identityNotFoundInPKCS12
        }
        self.identity = rawIdentity as! SecIdentity // swiftlint:disable:this force_cast
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        // `/usr/bin/openssl` is the macOS-shipped system
        // LibreSSL binary; Homebrew's `openssl` may live at
        // `/opt/homebrew/bin/openssl`.  Prefer the system
        // binary so the test is reproducible across hosts.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw TestCertFactoryError.opensslFailed(
                exitCode: process.terminationStatus,
                arguments: arguments
            )
        }
    }

    enum TestCertFactoryError: Error {
        case opensslFailed(exitCode: Int32, arguments: [String])
        case pkcs12ImportFailed(OSStatus)
        case identityNotFoundInPKCS12
    }
}

// MARK: - SendableIdentityBox

/// `@unchecked Sendable` wrapper around `SecIdentity`.
///
/// `SecIdentity` (CFTypeRef) isn't declared `Sendable` by
/// Apple, but it's effectively immutable — once created,
/// its underlying cert + key don't change.  Wrapping in
/// `@unchecked Sendable` is the standard pattern for
/// moving Security-framework references across
/// `@Sendable` closure boundaries in tests.
fileprivate struct SendableIdentityBox: @unchecked Sendable {
    let identity: SecIdentity
    init(_ identity: SecIdentity) { self.identity = identity }
}
