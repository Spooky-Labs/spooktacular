import Testing
import Foundation
import CryptoKit
@testable import SpookApplication

/// Tests for ``SignedRequestVerifier`` — the shared per-request
/// signature auth path used by both the guest agent and the
/// HTTP API server.
///
/// The verifier is security-critical: it replaces the
/// long-lived static Bearer tokens that previously authorised
/// readonly + runner operations. A regression here would
/// either (a) let an attacker impersonate a host via a replay
/// / skew-tolerance bug, or (b) reject legitimate controller
/// traffic via false rejections. Both matter; both are pinned
/// below.
@Suite("SignedRequestVerifier", .tags(.security, .cryptography))
struct SignedRequestVerifierTests {

    // MARK: - Signing helper

    /// Produces a valid X-Spook-* header triple plus the body
    /// for a round-trip test, signed by the given software key.
    /// Mirrors the canonical-string construction the host-side
    /// `GuestAgentClient.sign(...)` performs.
    private static func signedHeaders(
        method: String,
        path: String,
        body: Data,
        signer: P256.Signing.PrivateKey,
        timestamp: Date = Date(),
        nonce: String = UUID().uuidString
    ) throws -> [String: String] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let ts = iso.string(from: timestamp)

        let bodyHash = SHA256.hash(data: body)
            .map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method.uppercased())\n\(path)\n\(bodyHash)\n\(ts)\n\(nonce)"
        let ecdsa: P256.Signing.ECDSASignature = try signer.signature(for: Data(canonical.utf8))

        return [
            "x-spook-timestamp": ts,
            "x-spook-nonce": nonce,
            "x-spook-signature": ecdsa.rawRepresentation.base64EncodedString()
        ]
    }

    // MARK: - Happy path

    @Test("Valid signature from a trusted key verifies")
    func happyPath() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])

        let body = Data("{\"cmd\":\"ls\"}".utf8)
        let headers = try Self.signedHeaders(
            method: "POST", path: "/api/v1/files", body: body, signer: key
        )

        let accepted = try verifier.verify(
            method: "POST", path: "/api/v1/files",
            headers: headers, body: body
        )
        #expect(accepted.rawRepresentation == key.publicKey.rawRepresentation)
    }

    // MARK: - Trust allowlist

    @Test("First match wins — any trusted key can accept")
    func multiKeyAllowlist() throws {
        let alice = P256.Signing.PrivateKey()
        let bob = P256.Signing.PrivateKey()
        let carol = P256.Signing.PrivateKey()

        let verifier = SignedRequestVerifier(
            trustedKeys: [alice.publicKey, bob.publicKey, carol.publicKey]
        )

        let headers = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(), signer: bob
        )
        let accepted = try verifier.verify(
            method: "GET", path: "/health",
            headers: headers, body: Data()
        )
        #expect(accepted.rawRepresentation == bob.publicKey.rawRepresentation)
    }

    @Test("Untrusted signer is rejected even with valid signature")
    func untrustedSignerRejected() throws {
        let trusted = P256.Signing.PrivateKey()
        let attacker = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [trusted.publicKey])

        let headers = try Self.signedHeaders(
            method: "GET", path: "/api/v1/ports", body: Data(), signer: attacker
        )
        #expect(throws: SignedRequestVerifier.VerifyError.invalidSignature) {
            try verifier.verify(
                method: "GET", path: "/api/v1/ports",
                headers: headers, body: Data()
            )
        }
    }

    // MARK: - Missing headers

    @Test("Missing X-Spook-Signature is rejected as missingHeaders")
    func missingSignatureHeader() {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])
        let headers = [
            "x-spook-timestamp": "2026-04-17T18:30:00Z",
            "x-spook-nonce": UUID().uuidString
        ]
        #expect(throws: SignedRequestVerifier.VerifyError.missingHeaders) {
            try verifier.verify(method: "GET", path: "/health", headers: headers, body: Data())
        }
    }

    @Test("Empty allowlist fails closed (no trusted keys)")
    func emptyAllowlist() throws {
        let verifier = SignedRequestVerifier(trustedKeys: [])
        let key = P256.Signing.PrivateKey()
        let headers = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(), signer: key
        )
        #expect(throws: SignedRequestVerifier.VerifyError.invalidSignature) {
            try verifier.verify(method: "GET", path: "/health", headers: headers, body: Data())
        }
    }

    // MARK: - Timestamp skew

    @Test("Stale timestamp (beyond skew window) is rejected")
    func staleTimestamp() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        // Request timestamp 10 minutes ago.
        let tenMinAgo = now.addingTimeInterval(-600)
        let headers = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(),
            signer: key, timestamp: tenMinAgo
        )
        let verifier = SignedRequestVerifier(
            trustedKeys: [key.publicKey], clockSkew: 60, clock: { now }
        )
        #expect(throws: SignedRequestVerifier.VerifyError.timestampOutOfRange) {
            try verifier.verify(
                method: "GET", path: "/health",
                headers: headers, body: Data()
            )
        }
    }

    @Test("Future timestamp (beyond skew window) is rejected")
    func futureTimestamp() throws {
        let key = P256.Signing.PrivateKey()
        let now = Date()
        let tenMinFuture = now.addingTimeInterval(600)
        let headers = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(),
            signer: key, timestamp: tenMinFuture
        )
        let verifier = SignedRequestVerifier(
            trustedKeys: [key.publicKey], clockSkew: 60, clock: { now }
        )
        #expect(throws: SignedRequestVerifier.VerifyError.timestampOutOfRange) {
            try verifier.verify(
                method: "GET", path: "/health",
                headers: headers, body: Data()
            )
        }
    }

    // MARK: - Replay protection

    @Test("Same nonce twice is rejected on the second attempt")
    func replayRejected() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])

        let nonce = UUID().uuidString
        let headers = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(),
            signer: key, nonce: nonce
        )
        _ = try verifier.verify(
            method: "GET", path: "/health",
            headers: headers, body: Data()
        )
        #expect(throws: SignedRequestVerifier.VerifyError.replay) {
            try verifier.verify(
                method: "GET", path: "/health",
                headers: headers, body: Data()
            )
        }
    }

    @Test("Failed signature releases the nonce so legitimate retries work")
    func failedVerifyReleasesNonce() throws {
        let trusted = P256.Signing.PrivateKey()
        let attacker = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [trusted.publicKey])

        // First attempt: an attacker signs with their own key —
        // rejected. The nonce they claimed must not poison the
        // legitimate client's subsequent retry with the same nonce.
        let nonce = UUID().uuidString
        let attackerHeaders = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(),
            signer: attacker, nonce: nonce
        )
        _ = try? verifier.verify(
            method: "GET", path: "/health",
            headers: attackerHeaders, body: Data()
        )

        // Second attempt with the same nonce, signed by the
        // trusted key → should succeed.
        let legitHeaders = try Self.signedHeaders(
            method: "GET", path: "/health", body: Data(),
            signer: trusted, nonce: nonce
        )
        let accepted = try verifier.verify(
            method: "GET", path: "/health",
            headers: legitHeaders, body: Data()
        )
        #expect(accepted.rawRepresentation == trusted.publicKey.rawRepresentation)
    }

    // MARK: - Canonical-string tamper resistance

    @Test("Mismatched body is rejected (body-hash binding)")
    func tamperedBodyRejected() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])

        let realBody = Data("alice".utf8)
        let attackerBody = Data("bob".utf8)

        let headers = try Self.signedHeaders(
            method: "POST", path: "/api/v1/foo",
            body: realBody, signer: key
        )
        // Attacker presents the same signed headers but swaps
        // the body at send time.
        #expect(throws: SignedRequestVerifier.VerifyError.invalidSignature) {
            try verifier.verify(
                method: "POST", path: "/api/v1/foo",
                headers: headers, body: attackerBody
            )
        }
    }

    @Test("Mismatched path is rejected (path binding)")
    func tamperedPathRejected() throws {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])
        let headers = try Self.signedHeaders(
            method: "GET", path: "/api/v1/ports", body: Data(), signer: key
        )
        #expect(throws: SignedRequestVerifier.VerifyError.invalidSignature) {
            try verifier.verify(
                method: "GET", path: "/api/v1/exec",   // attacker routes to exec
                headers: headers, body: Data()
            )
        }
    }

    // MARK: - Malformed inputs

    @Test("Non-base64 signature is rejected as invalidSignature")
    func malformedSignatureRejected() {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])
        let headers = [
            "x-spook-timestamp": ISO8601DateFormatter().string(from: Date()),
            "x-spook-nonce": UUID().uuidString,
            "x-spook-signature": "not-base64!!!"
        ]
        #expect(throws: SignedRequestVerifier.VerifyError.invalidSignature) {
            try verifier.verify(method: "GET", path: "/health", headers: headers, body: Data())
        }
    }

    @Test("Signature with wrong byte length is rejected")
    func wrongSignatureLength() {
        let key = P256.Signing.PrivateKey()
        let verifier = SignedRequestVerifier(trustedKeys: [key.publicKey])
        // Base64 of 8 bytes instead of 64.
        let shortSig = Data([0, 1, 2, 3, 4, 5, 6, 7]).base64EncodedString()
        let headers = [
            "x-spook-timestamp": ISO8601DateFormatter().string(from: Date()),
            "x-spook-nonce": UUID().uuidString,
            "x-spook-signature": shortSig
        ]
        #expect(throws: SignedRequestVerifier.VerifyError.invalidSignature) {
            try verifier.verify(method: "GET", path: "/health", headers: headers, body: Data())
        }
    }
}
