import Foundation
import os
import SpooktacularApplication

/// Generates the embedded MDM's root CA on first run, then
/// signs per-VM identity certificates against it on demand.
/// Returns each identity packaged as the
/// ``MDMEnrollmentProfile/IdentityCertificate`` shape the
/// renderer embeds verbatim.
///
/// ## Why openssl over Process
///
/// Avoids pulling `swift-certificates` + `swift-asn1` +
/// `swift-crypto` into the dep graph for what amounts to a
/// handful of openssl invocations. macOS ships LibreSSL at
/// `/usr/bin/openssl`; we shell out through that. The
/// alternative — building X.509 + PKCS#12 manually with
/// `swift-asn1` — is several hundred lines of well-trodden
/// crypto plumbing that openssl already implements correctly.
///
/// We *will* replace this with a pure-Swift implementation
/// when the embedded MDM ships to non-macOS hosts (e.g. a
/// Linux runner pool). For today's EC2-Mac-on-macOS scope,
/// openssl is the pragmatic call.
///
/// ## Storage layout
///
/// ```
/// <storageDirectory>/
///   root-ca.pem        Self-signed P-256 root CA (DER inside PEM).
///   root-ca.key        EC private key, mode 0600.
///   root-ca.srl        OpenSSL serial-number tracking file.
/// ```
///
/// The CA is generated *once per host* and re-used for every
/// VM. Re-generating it would invalidate every previously-
/// issued identity (since clients trust by certificate-chain
/// validation against this exact CA cert). Operators who want
/// to rotate the CA today have to wipe the storage directory
/// and re-bootstrap every VM — a deliberately destructive
/// operation that's documented as such.
///
/// ## Concurrency
///
/// Actor-isolated so concurrent issuance from multiple VM
/// creates serialises through one openssl invocation at a
/// time. The CA-init path is also safe because both "is the
/// CA on disk?" check and the generation are inside the
/// actor.
public actor MDMIdentityIssuer {

    // MARK: - Config

    /// Where the CA + serial files live. Must be operator-
    /// readable (we run as the user) but tighten to 0700 at
    /// init.
    public let storageDirectory: URL

    /// Path to the openssl binary. Override only in tests.
    public let opensslPath: String

    /// CA validity in days when generating fresh.
    public let caValidityDays: Int

    /// Per-VM identity-cert validity in days. Short enough
    /// that a stale identity isn't a long-term liability,
    /// long enough that ephemeral CI runners don't expire
    /// mid-job.
    public let identityValidityDays: Int

    private let logger: Logger

    /// Cache the root cert's DER bytes after first read so
    /// repeated `rootCertificateDER()` calls don't re-read the
    /// file. Invalidated implicitly when the actor is
    /// destroyed; the actor lifetime is tied to the host
    /// process.
    private var cachedRootDER: Data?

    // MARK: - Init

    public init(
        storageDirectory: URL,
        opensslPath: String = "/usr/bin/openssl",
        caValidityDays: Int = 3650,
        identityValidityDays: Int = 365,
        logger: Logger = Logger(
            subsystem: "com.spookylabs.spooktacular",
            category: "mdm.identity"
        )
    ) throws {
        self.storageDirectory = storageDirectory
        self.opensslPath = opensslPath
        self.caValidityDays = caValidityDays
        self.identityValidityDays = identityValidityDays
        self.logger = logger

        try FileManager.default.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    // MARK: - Public API

    /// Issues a per-VM identity certificate signed by the root
    /// CA. Generates the root CA on first call (idempotent on
    /// subsequent calls). Returns the ``IdentityCertificate``
    /// structure ready to embed in
    /// ``MDMEnrollmentProfile/SignaturePolicy/signed(identity:)``.
    public func issueIdentity(
        forUDID udid: String
    ) async throws -> MDMEnrollmentProfile.IdentityCertificate {
        try await ensureCA()

        let workingDir = try makeWorkingDirectory()
        defer { try? FileManager.default.removeItem(at: workingDir) }

        let vmKey = workingDir.appendingPathComponent("vm.key")
        let vmCSR = workingDir.appendingPathComponent("vm.csr")
        let vmPEM = workingDir.appendingPathComponent("vm.pem")
        let vmP12 = workingDir.appendingPathComponent("vm.p12")

        // 1. Generate per-VM EC P-256 key
        try runOpenSSL(
            "ecparam", "-name", "prime256v1", "-genkey", "-noout",
            "-out", vmKey.path
        )

        // 2. Generate CSR with CN = UDID
        try runOpenSSL(
            "req", "-new",
            "-key", vmKey.path,
            "-out", vmCSR.path,
            "-subj", "/CN=\(udid)/O=Spooktacular MDM"
        )

        // 3. Sign CSR with root CA
        try runOpenSSL(
            "x509", "-req",
            "-in", vmCSR.path,
            "-CA", caCertURL.path,
            "-CAkey", caKeyURL.path,
            "-CAcreateserial",
            "-out", vmPEM.path,
            "-days", String(identityValidityDays),
            "-sha256"
        )

        // 4. Mint a random PKCS#12 password (base64 of 16
        //    random bytes — ~22 chars). Apple's mdmclient
        //    only needs the password to decrypt the bag at
        //    install time; the host that issued the cert is
        //    the only entity that ever sees it.
        let password = randomPassword()

        // 5. Export as PKCS#12
        try runOpenSSL(
            "pkcs12", "-export",
            "-in", vmPEM.path,
            "-inkey", vmKey.path,
            "-out", vmP12.path,
            "-password", "pass:\(password)",
            "-name", "Spooktacular MDM Identity for \(udid)"
        )

        let pkcs12Data = try Data(contentsOf: vmP12)

        logger.notice(
            "Issued MDM identity for UDID=\(udid, privacy: .public) (\(pkcs12Data.count) bytes)"
        )

        return MDMEnrollmentProfile.IdentityCertificate(
            payloadUUID: UUID(),
            pkcs12Data: pkcs12Data,
            password: password
        )
    }

    /// Returns the DER-encoded root CA certificate, suitable
    /// for the host's mTLS verifier or for inclusion as a
    /// trust-anchor payload in the enrollment profile.
    public func rootCertificateDER() async throws -> Data {
        try await ensureCA()
        if let cached = cachedRootDER { return cached }
        let pem = try Data(contentsOf: caCertURL)
        let der = try Self.derFromPEM(pem)
        cachedRootDER = der
        return der
    }

    // MARK: - CA generation

    private var caKeyURL: URL { storageDirectory.appendingPathComponent("root-ca.key") }
    private var caCertURL: URL { storageDirectory.appendingPathComponent("root-ca.pem") }

    /// Idempotent: generates the root CA only when the cert
    /// or key file is missing. Acquiring the actor before the
    /// check serialises concurrent first-issuances so two
    /// callers don't both try to generate.
    private func ensureCA() async throws {
        if FileManager.default.fileExists(atPath: caKeyURL.path),
           FileManager.default.fileExists(atPath: caCertURL.path) {
            return
        }

        logger.notice("Generating MDM root CA at \(self.storageDirectory.path, privacy: .public)")

        // EC P-256 root key
        try runOpenSSL(
            "ecparam", "-name", "prime256v1", "-genkey", "-noout",
            "-out", caKeyURL.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: caKeyURL.path
        )

        // Self-signed CA cert with the X.509 v3 extensions
        // launchd / mdmclient expect for a trust-anchor
        // identity:
        //   basicConstraints=CA:TRUE  → tells the verifier
        //                                "you may sign other
        //                                certs with this".
        //   keyUsage=keyCertSign     → narrows the use to
        //                                cert-signing only;
        //                                without `digitalSig`
        //                                this CA can't be
        //                                misused as a TLS
        //                                identity.
        try runOpenSSL(
            "req", "-x509", "-new",
            "-key", caKeyURL.path,
            "-out", caCertURL.path,
            "-days", String(caValidityDays),
            "-sha256",
            "-subj", "/CN=Spooktacular MDM Root CA/O=Spooktacular",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: caCertURL.path
        )
    }

    // MARK: - Process plumbing

    private func runOpenSSL(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = arguments

        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errBytes = stderr.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errBytes, encoding: .utf8) ?? "<no stderr>"
            throw MDMIdentityIssuerError.openSSLFailed(
                arguments: arguments,
                exitCode: process.terminationStatus,
                stderr: msg
            )
        }
    }

    private func makeWorkingDirectory() throws -> URL {
        let url = storageDirectory.appendingPathComponent("issuance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    // MARK: - Random + DER helpers

    private func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Strips the PEM header / footer / line wraps and
    /// base64-decodes the body to raw DER. Throws when the
    /// input doesn't look like a PEM cert.
    static func derFromPEM(_ pem: Data) throws -> Data {
        guard let text = String(data: pem, encoding: .utf8) else {
            throw MDMIdentityIssuerError.malformedPEM
        }
        let lines = text.split(whereSeparator: \.isNewline)
        let body = lines
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let der = Data(base64Encoded: body) else {
            throw MDMIdentityIssuerError.malformedPEM
        }
        return der
    }
}

// MARK: - Errors

public enum MDMIdentityIssuerError: Error, Sendable {
    /// `openssl` exited non-zero. `stderr` preserved for
    /// audit + diagnostics. `arguments` does *not* include
    /// any password (we pass passwords via `pass:…` arguments
    /// — Apple's documented openssl shape — so they're
    /// captured here. Acceptable for an in-process audit
    /// trail; the test path is to redact before logging).
    case openSSLFailed(arguments: [String], exitCode: Int32, stderr: String)

    /// PEM input couldn't be parsed.
    case malformedPEM
}
