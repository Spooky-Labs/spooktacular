import Testing
import Foundation
import CryptoKit
@testable import SpookCore
@testable import SpookApplication

@Suite("spook audit verify (SignedTreeHeadVerifier)")
struct SpookAuditVerifyTests {

    // MARK: - Golden-path helpers

    private struct Scenario {
        let tmp: TempDirectory
        let recordPath: String
        let auditPathPath: String
        let treeHeadPath: String
        let publicKeyPath: String
        let privateKey: Curve25519.Signing.PrivateKey
    }

    private static func buildScenario(tamperWithRoot: Bool = false) throws -> Scenario {
        let tmp = TempDirectory()
        let recordBytes = Data("{\"action\":\"create\"}".utf8)
        let recordPath = tmp.file("record.json").path
        try recordBytes.write(to: URL(filePath: recordPath))

        // 1-leaf tree: root == leafHash.
        let leafHash = MerkleTreeVerifier.leafHash(recordBytes)
        let rootHex = tamperWithRoot
            ? String(repeating: "0", count: 64)
            : leafHash.map { String(format: "%02x", $0) }.joined()

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let key = Curve25519.Signing.PrivateKey()

        // TBS per RFC 6962 §3.5.
        var message = Data()
        message.append(0x00)
        message.append(0x01)
        let ts = UInt64(timestamp.timeIntervalSince1970 * 1000)
        withUnsafeBytes(of: ts.bigEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(1).bigEndian) { message.append(contentsOf: $0) }
        message.append(MerkleTreeVerifier.hexToData(rootHex))
        let signature = try key.signature(for: message)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let sthJSON = """
        {"treeSize":1,"timestamp":"\(iso.string(from: timestamp))","rootHash":"\(rootHex)","signature":"\(signature.base64EncodedString())"}
        """
        let treeHeadPath = tmp.file("sth.json").path
        try Data(sthJSON.utf8).write(to: URL(filePath: treeHeadPath))

        // Empty audit path — 1-leaf tree.
        let auditPathJSON = "{\"leafIndex\":0,\"auditPath\":[]}"
        let auditPathPath = tmp.file("path.json").path
        try Data(auditPathJSON.utf8).write(to: URL(filePath: auditPathPath))

        // Bare 32-byte Ed25519 key in PEM.
        let pem = "-----BEGIN PUBLIC KEY-----\n\(key.publicKey.rawRepresentation.base64EncodedString())\n-----END PUBLIC KEY-----\n"
        let publicKeyPath = tmp.file("pub.pem").path
        try Data(pem.utf8).write(to: URL(filePath: publicKeyPath))

        return Scenario(
            tmp: tmp,
            recordPath: recordPath,
            auditPathPath: auditPathPath,
            treeHeadPath: treeHeadPath,
            publicKeyPath: publicKeyPath,
            privateKey: key
        )
    }

    // MARK: - Tests

    @Test("happy path: inclusion verifies and signature is valid")
    func happyPath() throws {
        let s = try Self.buildScenario()
        let outcome = try SignedTreeHeadVerifier.verify(
            recordPath: s.recordPath,
            auditPathPath: s.auditPathPath,
            treeHeadPath: s.treeHeadPath,
            publicKeyPath: s.publicKeyPath
        )
        #expect(outcome.signatureValid)
        #expect(outcome.inclusionValid)
        #expect(outcome.reconstructedRootHex == outcome.expectedRootHex)
    }

    @Test("tampered root: inclusion fails but signature check is still run")
    func tamperedRoot() throws {
        let s = try Self.buildScenario(tamperWithRoot: true)
        let outcome = try SignedTreeHeadVerifier.verify(
            recordPath: s.recordPath,
            auditPathPath: s.auditPathPath,
            treeHeadPath: s.treeHeadPath,
            publicKeyPath: s.publicKeyPath
        )
        #expect(!outcome.inclusionValid)
        // Signature still verifies because the attacker signed the
        // bogus root; inclusion is the check that catches it.
        #expect(outcome.signatureValid)
    }

    @Test("missing record file: throws Error.missingFile")
    func missingRecord() throws {
        let s = try Self.buildScenario()
        do {
            _ = try SignedTreeHeadVerifier.verify(
                recordPath: s.tmp.file("nope.json").path,
                auditPathPath: s.auditPathPath,
                treeHeadPath: s.treeHeadPath,
                publicKeyPath: s.publicKeyPath
            )
            Issue.record("should have thrown for missing file")
        } catch SignedTreeHeadVerifier.Error.missingFile {
            return
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("bad public key: throws Error.badPublicKey")
    func badPublicKey() throws {
        let s = try Self.buildScenario()
        let badPath = s.tmp.file("bad.pem").path
        try Data("-----BEGIN PUBLIC KEY-----\nSEVMTE8=\n-----END PUBLIC KEY-----\n".utf8)
            .write(to: URL(filePath: badPath))
        do {
            _ = try SignedTreeHeadVerifier.verify(
                recordPath: s.recordPath,
                auditPathPath: s.auditPathPath,
                treeHeadPath: s.treeHeadPath,
                publicKeyPath: badPath
            )
            Issue.record("should have thrown for a too-short key")
        } catch SignedTreeHeadVerifier.Error.badPublicKey {
            return
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test("wrong signer's key: signatureValid is false")
    func wrongKey() throws {
        let s = try Self.buildScenario()
        let other = Curve25519.Signing.PrivateKey()
        let pem = "-----BEGIN PUBLIC KEY-----\n\(other.publicKey.rawRepresentation.base64EncodedString())\n-----END PUBLIC KEY-----\n"
        let otherPath = s.tmp.file("other.pem").path
        try Data(pem.utf8).write(to: URL(filePath: otherPath))

        let outcome = try SignedTreeHeadVerifier.verify(
            recordPath: s.recordPath,
            auditPathPath: s.auditPathPath,
            treeHeadPath: s.treeHeadPath,
            publicKeyPath: otherPath
        )
        #expect(!outcome.signatureValid)
    }

    @Test("malformed audit-path JSON: throws malformedJSON")
    func malformedJSON() throws {
        let s = try Self.buildScenario()
        try Data("not json".utf8).write(to: URL(filePath: s.auditPathPath))
        do {
            _ = try SignedTreeHeadVerifier.verify(
                recordPath: s.recordPath,
                auditPathPath: s.auditPathPath,
                treeHeadPath: s.treeHeadPath,
                publicKeyPath: s.publicKeyPath
            )
            Issue.record("should have thrown for malformed JSON")
        } catch SignedTreeHeadVerifier.Error.malformedJSON {
            return
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }
}
