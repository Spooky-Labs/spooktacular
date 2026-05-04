import Foundation
import Security
import Testing
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication

/// Phase-2 tests — exercise real openssl + verify the
/// resulting PKCS#12 round-trips through Apple's
/// `SecPKCS12Import`. Skips silently if `/usr/bin/openssl`
/// isn't available (CI sandboxes / non-macOS).
@Suite("MDM identity issuer (real openssl)")
struct MDMIdentityIssuerTests {

    private func opensslAvailable() -> Bool {
        FileManager.default.fileExists(atPath: "/usr/bin/openssl")
    }

    private func makeIssuer(in tmp: URL) throws -> MDMIdentityIssuer {
        try MDMIdentityIssuer(
            storageDirectory: tmp,
            // Short validity so tests don't bake long-lived
            // assumptions into the cert metadata.
            caValidityDays: 7,
            identityValidityDays: 1
        )
    }

    private func tmpDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-mdm-issuer-test-\(UUID())")
        return url
    }

    // MARK: - CA generation

    @Test("First call generates root-ca.pem + root-ca.key")
    func generatesCA() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        _ = try await issuer.rootCertificateDER()

        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("root-ca.pem").path))
        #expect(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("root-ca.key").path))
    }

    @Test("Second call reuses existing CA — file mtimes don't change")
    func reusesCA() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        _ = try await issuer.rootCertificateDER()
        let firstAttrs = try FileManager.default.attributesOfItem(
            atPath: tmp.appendingPathComponent("root-ca.pem").path
        )
        let firstMTime = try #require(firstAttrs[.modificationDate] as? Date)

        // Sleep just enough that an mtime change would be detectable.
        try await Task.sleep(for: .milliseconds(50))

        _ = try await issuer.rootCertificateDER()
        let secondAttrs = try FileManager.default.attributesOfItem(
            atPath: tmp.appendingPathComponent("root-ca.pem").path
        )
        let secondMTime = try #require(secondAttrs[.modificationDate] as? Date)

        #expect(firstMTime == secondMTime, "CA should not be regenerated on second call")
    }

    @Test("Root cert DER parses as a SecCertificate (validates the bytes are a real X.509)")
    func rootCertParsesAsSecCertificate() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        let der = try await issuer.rootCertificateDER()
        let cert = SecCertificateCreateWithData(nil, der as CFData)
        #expect(cert != nil, "DER did not parse into a SecCertificate")
        if let cert {
            // Subject CN should be our root-CA name
            let summary = SecCertificateCopySubjectSummary(cert) as String?
            #expect(summary?.contains("Spooktacular MDM Root CA") == true)
        }
    }

    // MARK: - Identity issuance

    @Test("Issued identity PKCS#12 imports cleanly via SecPKCS12Import")
    func issuedIdentityImports() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        let identity = try await issuer.issueIdentity(
            forUDID: "00008103-AAAABBBBCCCCDDDD"
        )
        #expect(!identity.pkcs12Data.isEmpty)
        #expect(!identity.password.isEmpty)

        let options: [String: Any] = [kSecImportExportPassphrase as String: identity.password]
        var imported: CFArray?
        let status = SecPKCS12Import(
            identity.pkcs12Data as CFData,
            options as CFDictionary,
            &imported
        )
        #expect(status == errSecSuccess, "SecPKCS12Import returned \(status)")

        let items = imported as? [[String: Any]] ?? []
        #expect(!items.isEmpty, "Expected at least one item in the imported PKCS#12 bag")
        // The first item should expose a SecIdentityRef
        let identRef = items.first?[kSecImportItemIdentity as String]
        #expect(identRef != nil, "Imported bag should expose an identity (cert + key)")
    }

    @Test("Different UDIDs produce different PKCS#12 bytes (per-VM uniqueness)")
    func uniquePerUDID() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        let a = try await issuer.issueIdentity(forUDID: "udid-A")
        let b = try await issuer.issueIdentity(forUDID: "udid-B")

        // Different keypair + different CN → different bytes
        #expect(a.pkcs12Data != b.pkcs12Data)
        // Different randomly-generated passwords
        #expect(a.password != b.password)
        // Different payload UUIDs (the renderer's reference)
        #expect(a.payloadUUID != b.payloadUUID)
    }

    @Test("Identity certificate's CN matches the supplied UDID")
    func identityCNMatchesUDID() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        let udid = "00008103-FACE0FF1CEFOREVER"
        let identity = try await issuer.issueIdentity(forUDID: udid)

        let options: [String: Any] = [kSecImportExportPassphrase as String: identity.password]
        var imported: CFArray?
        let status = SecPKCS12Import(
            identity.pkcs12Data as CFData,
            options as CFDictionary,
            &imported
        )
        try #require(status == errSecSuccess)
        let items = imported as? [[String: Any]] ?? []
        guard let ref = items.first?[kSecImportItemIdentity as String] else {
            Issue.record("No identity in imported bag")
            return
        }
        let identityRef = ref as! SecIdentity

        var cert: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identityRef, &cert)
        try #require(copyStatus == errSecSuccess)
        let summary = SecCertificateCopySubjectSummary(cert!) as String?
        #expect(summary?.contains(udid) == true,
                "Certificate CN should contain UDID, got: \(summary ?? "<nil>")")
    }

    // MARK: - Concurrency

    @Test("Concurrent issuance for two UDIDs both succeed (actor serialises openssl)")
    func concurrentIssuance() async throws {
        try #require(opensslAvailable())
        let tmp = tmpDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let issuer = try makeIssuer(in: tmp)

        async let a = issuer.issueIdentity(forUDID: "udid-concurrent-A")
        async let b = issuer.issueIdentity(forUDID: "udid-concurrent-B")
        let (rA, rB) = try await (a, b)
        #expect(!rA.pkcs12Data.isEmpty)
        #expect(!rB.pkcs12Data.isEmpty)
        #expect(rA.payloadUUID != rB.payloadUUID)
    }
}
