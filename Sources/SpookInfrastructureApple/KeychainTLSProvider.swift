import Foundation
import SpookCore
import SpookApplication
import Security
import CryptoKit

/// Infrastructure-layer refinement of ``TLSIdentityProvider`` that
/// carries the anchor-pinning contract.
///
/// Declared here (not in ``SpookCore``) because the method
/// signature references `SecCertificate` — a Security-framework
/// type that Clean Architecture prohibits the domain layer from
/// importing. Callers that genuinely need pinning depend on this
/// protocol directly; callers that only need the generic mTLS
/// client stay on the vanilla ``TLSIdentityProvider``.
///
/// Apple's TLS hardening guide
/// (https://developer.apple.com/documentation/security/preventing-insecure-network-connections)
/// recommends anchor pinning for sensitive endpoints. The
/// ``makeHTTPClient(pinnedCertificates:)`` contract: the returned
/// client **MUST** reject any server chain that does not
/// terminate at one of the passed-in anchors.
public protocol PinnedTLSIdentityProvider: TLSIdentityProvider {

    /// Returns an ``HTTPClient`` pinned to the supplied anchor
    /// certificates.
    ///
    /// Implementations MUST:
    ///
    /// - Replace the system trust store during server-trust
    ///   evaluation with the passed-in anchors (e.g., via
    ///   `SecTrustSetAnchorCertificates` +
    ///   `SecTrustSetAnchorCertificatesOnly`).
    /// - Reject any handshake whose leaf certificate does not
    ///   chain to at least one of `pinnedCertificates`.
    /// - Continue to present client-certificate credentials for
    ///   mTLS challenges when the implementation is stateful
    ///   about an identity (as ``KeychainTLSProvider`` is).
    ///
    /// Passing an empty array is a programmer error — the
    /// pinning promise is meaningless without anchors and
    /// implementations MUST throw rather than silently accept.
    func makeHTTPClient(pinnedCertificates: [SecCertificate]) throws -> any HTTPClient
}

/// Loads a client identity from the Keychain and configures a
/// `URLSession` for mutual TLS (mTLS).
///
/// The provider handles two kinds of authentication challenge:
///
/// | Challenge method                        | Action                                  |
/// |-----------------------------------------|-----------------------------------------|
/// | `NSURLAuthenticationMethodServerTrust`   | Evaluate against the pinned CA          |
/// | `NSURLAuthenticationMethodClientCertificate` | Present the client `SecIdentity`   |
///
/// ## Usage
///
/// ```swift
/// let tls = try KeychainTLSProvider(
///     certPath: "/etc/spooktacular/client.pem",
///     keyPath:  "/etc/spooktacular/client-key.pem",
///     caPath:   "/etc/spooktacular/ca.pem"
/// )
/// let session = tls.configuredSession()
/// ```
public final class KeychainTLSProvider: NSObject, PinnedTLSIdentityProvider, URLSessionDelegate, @unchecked Sendable {

    // MARK: - Stored Properties

    private let clientIdentity: SecIdentity
    private let trustedCACertificate: SecCertificate

    // MARK: - Initializers

    /// Creates a provider from pre-loaded Security objects.
    ///
    /// - Parameters:
    ///   - clientIdentity: A `SecIdentity` containing the client
    ///     certificate and its matching private key.
    ///   - trustedCA: The CA certificate used to verify the server.
    public init(clientIdentity: SecIdentity, trustedCA: SecCertificate) {
        self.clientIdentity = clientIdentity
        self.trustedCACertificate = trustedCA
    }

    /// Convenience initializer that loads PEM-encoded files from disk.
    ///
    /// The certificate and key are imported into a temporary Keychain
    /// item so that `SecIdentity` can pair them.
    ///
    /// - Parameters:
    ///   - certPath: Path to the PEM-encoded client certificate.
    ///   - keyPath: Path to the PEM-encoded client private key.
    ///   - caPath: Path to the PEM-encoded CA certificate.
    /// - Throws: If any file cannot be read or if the Security
    ///   framework rejects the data.
    public convenience init(certPath: String, keyPath: String, caPath: String) throws {
        let certData = try Data(contentsOf: URL(filePath: certPath))
        let keyData  = try Data(contentsOf: URL(filePath: keyPath))
        let caData   = try Data(contentsOf: URL(filePath: caPath))

        // Import client certificate + key into a PKCS #12 identity.
        let identity = try Self.importIdentity(certDER: Self.decodePEM(certData),
                                               keyDER: Self.decodePEM(keyData))

        guard let caCert = SecCertificateCreateWithData(nil, Self.decodePEM(caData) as CFData) else {
            throw TLSProviderError.invalidCACertificate
        }

        self.init(clientIdentity: identity, trustedCA: caCert)
    }

    // MARK: - TLSIdentityProvider

    /// Returns an ``HTTPClient`` wired to a `URLSession` whose delegate
    /// handles mTLS challenges with anchor-pinned server trust.
    ///
    /// Pins the minimum TLS version to **1.3**. TLS 1.2 and earlier
    /// are not accepted — 1.3 eliminates whole classes of
    /// negotiation-downgrade bugs and has been mandated for
    /// financial/government deployments since 2023.
    public func makeHTTPClient() -> any HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        return URLSessionHTTPClient(session: session)
    }

    /// Returns an ``HTTPClient`` pinned to the passed-in anchor
    /// certificates, satisfying the
    /// ``TLSIdentityProvider/makeHTTPClient(pinnedCertificates:)``
    /// contract.
    ///
    /// The returned client evaluates every server chain against
    /// **only** the supplied anchors — any chain that does not
    /// terminate at one of them is rejected via
    /// `cancelAuthenticationChallenge`. Client-certificate
    /// challenges still present the stored ``clientIdentity``.
    ///
    /// - Parameter pinnedCertificates: The anchor certificates.
    ///   Must be non-empty; an empty array throws
    ///   ``TLSProviderError/invalidCACertificate`` because a
    ///   pinned client with no anchors accepts no servers.
    /// - Returns: A mTLS `HTTPClient` with pinned server trust.
    public func makeHTTPClient(pinnedCertificates: [SecCertificate]) throws -> any HTTPClient {
        guard !pinnedCertificates.isEmpty else {
            throw TLSProviderError.invalidCACertificate
        }
        let delegate = PinnedAnchorsDelegate(
            clientIdentity: clientIdentity,
            anchors: pinnedCertificates
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        let session = URLSession(
            configuration: configuration, delegate: delegate, delegateQueue: nil
        )
        return URLSessionHTTPClient(session: session)
    }

    // MARK: - URLSessionDelegate

    /// Responds to TLS authentication challenges.
    ///
    /// - Server trust challenges are evaluated against ``trustedCACertificate``.
    /// - Client certificate challenges present ``clientIdentity``.
    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        switch method {
        case NSURLAuthenticationMethodServerTrust:
            handleServerTrust(challenge: challenge, completionHandler: completionHandler)

        case NSURLAuthenticationMethodClientCertificate:
            let credential = URLCredential(identity: clientIdentity,
                                           certificates: nil,
                                           persistence: .forSession)
            completionHandler(.useCredential, credential)

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Private Helpers

    /// Evaluates the server's trust object against the pinned CA.
    private func handleServerTrust(
        challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        SecTrustSetAnchorCertificates(serverTrust, [trustedCACertificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(serverTrust, true)

        var error: CFError?
        if SecTrustEvaluateWithError(serverTrust, &error) {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Strips PEM armor and returns raw DER bytes.
    private static func decodePEM(_ pem: Data) -> Data {
        guard let pemString = String(data: pem, encoding: .utf8) else { return pem }
        let base64 = pemString
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64) ?? pem
    }

    /// Tries to import `keyDER` as the given `SecKey` type. Returns
    /// `nil` on any failure so callers can cascade through supported
    /// algorithms.
    private static func tryImportKey(_ data: Data, type: CFString) -> SecKey? {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: type,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        return SecKeyCreateWithData(data as CFData, attrs as CFDictionary, &error)
    }

    /// Prefix for Keychain labels/tags created by this provider.
    ///
    /// Using a deterministic prefix scoped to the certificate's SHA-256
    /// fingerprint means repeated imports of the same cert produce one
    /// Keychain entry — never a growing stack — and a different cert
    /// produces a distinct entry that can be cleaned up independently.
    private static let keychainLabelPrefix = "com.spooktacular.tls.client"

    /// Imports a DER-encoded certificate and private key and returns a
    /// `SecIdentity` pairing them.
    ///
    /// The cert and key are inserted into the user's login Keychain with
    /// an application tag derived from the certificate's SHA-256 digest.
    /// Any prior entries with the same tag are removed first, preventing
    /// the unbounded growth that a naive `SecItemAdd` would produce on
    /// repeated imports. The private key is marked
    /// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so it never
    /// syncs off the host via iCloud Keychain.
    private static func importIdentity(certDER: Data, keyDER: Data) throws -> SecIdentity {
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw TLSProviderError.invalidClientCertificate
        }

        // Try ECDSA (P-256) first — faster signatures, smaller keys,
        // and the modern default. Fall back to RSA for compatibility
        // with legacy CAs that haven't migrated yet.
        //
        // `SecKeyCreateWithData` returns nil + an error when the key
        // material doesn't match the declared type; we catch both
        // cases and try the other algorithm before giving up.
        let privateKey: SecKey
        if let ec = tryImportKey(keyDER, type: kSecAttrKeyTypeECSECPrimeRandom) {
            privateKey = ec
        } else if let rsa = tryImportKey(keyDER, type: kSecAttrKeyTypeRSA) {
            privateKey = rsa
        } else {
            throw TLSProviderError.invalidPrivateKey(nil)
        }

        let fingerprint = Data(SHA256.hash(data: certDER))
        let label = "\(keychainLabelPrefix)-\(fingerprint.base64EncodedString())"
        let applicationTag = Data("\(label).key".utf8)

        // Purge any prior entries for this exact certificate fingerprint.
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
        ] as CFDictionary)

        let certStatus = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw TLSProviderError.keychainError(certStatus)
        }

        let keyStatus = SecItemAdd([
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw TLSProviderError.keychainError(keyStatus)
        }

        // Retrieve the identity scoped to our label — never any other
        // identity that happens to live in the same Keychain.
        var identityRef: CFTypeRef?
        let identityStatus = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ] as CFDictionary, &identityRef)
        guard identityStatus == errSecSuccess, let identity = identityRef else {
            throw TLSProviderError.identityNotFound(identityStatus)
        }

        // Confirm the Keychain actually returned a SecIdentity.
        // A mismatched dynamic type would trap on force-cast, which
        // on a first-run path that handles user-supplied cert/key
        // bytes is a denial-of-service footgun. `CFGetTypeID` is the
        // Apple-documented way to type-check an opaque CF ref —
        // https://developer.apple.com/documentation/security/secidentity .
        //
        // After the type-id check, we bridge via `unsafeBitCast`.
        // Swift's `as?` from `CFTypeRef` to a CoreFoundation type
        // always succeeds on the Obj-C bridge regardless of the CF
        // type id, so `as?` would be a misleading check. `unsafeBitCast`
        // under a CFGetTypeID guard is the standard Swift idiom for
        // narrowing `CFTypeRef` to a specific CF subclass.
        guard CFGetTypeID(identity) == SecIdentityGetTypeID() else {
            throw TLSProviderError.identityNotFound(identityStatus)
        }
        let secIdentity: SecIdentity = unsafeBitCast(identity, to: SecIdentity.self)

        // Cert/key pairing verification. `SecIdentityCreateWithCertificate`
        // and the Keychain lookup will happily return an identity whose
        // cert+key are from *different* provisioning events if the
        // Keychain has stray items — the label filter reduces the
        // blast radius but doesn't close it. To prove the pairing is
        // cryptographically sound, we sign a known nonce with the
        // identity's private key and verify the signature with the
        // cert's public key. A mismatch throws `.invalidIdentity`
        // before the identity ever reaches a TLS handshake.
        try Self.verifyIdentityPairing(secIdentity)
        return secIdentity
    }

    /// Proves the identity's private key matches the certificate's
    /// public key via a round-trip sign + verify over a fresh
    /// random nonce.
    ///
    /// This is the Apple-documented (`SecIdentityCopyCertificate` +
    /// `SecIdentityCopyPrivateKey` + `SecKeyCreateSignature` +
    /// `SecKeyVerifySignature`) approach. See
    /// https://developer.apple.com/documentation/security/seckey .
    /// The algorithm is selected by the cert's key type:
    ///
    /// - EC keys sign with `ecdsaSignatureMessageX962SHA256`
    /// - RSA keys sign with `rsaSignatureMessagePKCS1v15SHA256`
    ///
    /// The nonce is 32 random bytes from the system RNG, so no
    /// attacker-influenced signing oracle is created.
    private static func verifyIdentityPairing(_ identity: SecIdentity) throws {
        var certRef: SecCertificate?
        let certStatus = SecIdentityCopyCertificate(identity, &certRef)
        guard certStatus == errSecSuccess, let cert = certRef else {
            throw TLSProviderError.invalidIdentity("SecIdentityCopyCertificate failed (OSStatus \(certStatus))")
        }
        var privRef: SecKey?
        let privStatus = SecIdentityCopyPrivateKey(identity, &privRef)
        guard privStatus == errSecSuccess, let privateKey = privRef else {
            throw TLSProviderError.invalidIdentity("SecIdentityCopyPrivateKey failed (OSStatus \(privStatus))")
        }
        guard let publicKey = SecCertificateCopyKey(cert) else {
            throw TLSProviderError.invalidIdentity("SecCertificateCopyKey returned nil")
        }

        // Branch on key type — ECDSA vs RSA algorithm constants.
        // `kSecAttrKeyType*` constants are `CFString` — we compare
        // the bridged Swift String rather than switching, which
        // requires expression pattern parity.
        let privAttrs = SecKeyCopyAttributes(privateKey) as? [String: Any]
        let keyType = privAttrs?[kSecAttrKeyType as String] as? String
        let algo: SecKeyAlgorithm
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            algo = .ecdsaSignatureMessageX962SHA256
        } else if keyType == (kSecAttrKeyTypeRSA as String) {
            algo = .rsaSignatureMessagePKCS1v15SHA256
        } else {
            throw TLSProviderError.invalidIdentity("Unsupported key type \(keyType ?? "(nil)") — expected EC or RSA")
        }

        // Fresh 32-byte nonce from the system RNG.
        var nonceBytes = [UInt8](repeating: 0, count: 32)
        let rngStatus = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard rngStatus == errSecSuccess else {
            throw TLSProviderError.invalidIdentity("SecRandomCopyBytes failed (OSStatus \(rngStatus))")
        }
        let nonce = Data(nonceBytes)

        var signErr: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey, algo, nonce as CFData, &signErr
        ) as Data? else {
            let err = signErr?.takeRetainedValue()
            throw TLSProviderError.invalidIdentity("SecKeyCreateSignature failed: \(err?.localizedDescription ?? "(unknown)")")
        }

        var verifyErr: Unmanaged<CFError>?
        let valid = SecKeyVerifySignature(
            publicKey, algo, nonce as CFData, signature as CFData, &verifyErr
        )
        guard valid else {
            throw TLSProviderError.invalidIdentity(
                "Private key does not match certificate's public key — identity pairing is broken"
            )
        }
    }

    /// Removes Keychain items associated with a specific client certificate.
    ///
    /// Call this during uninstall or when rotating to a new client cert
    /// to purge the prior identity's entries from the login Keychain.
    ///
    /// - Parameter certDER: The DER-encoded certificate whose Keychain
    ///   entries should be removed. The fingerprint is used to locate
    ///   the matching cert and private key.
    public static func purgeKeychainItems(forCertificateDER certDER: Data) {
        let fingerprint = Data(SHA256.hash(data: certDER))
        let label = "\(keychainLabelPrefix)-\(fingerprint.base64EncodedString())"
        let applicationTag = Data("\(label).key".utf8)

        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
        ] as CFDictionary)
    }
}

// MARK: - Pinned-Anchors Delegate

/// `URLSessionDelegate` that evaluates every server-trust
/// challenge against a fixed set of anchor certificates.
///
/// Used by ``KeychainTLSProvider/makeHTTPClient(pinnedCertificates:)``
/// to satisfy the
/// ``TLSIdentityProvider/makeHTTPClient(pinnedCertificates:)``
/// pinning contract — any chain that does not terminate at one
/// of the pinned anchors is rejected outright. Apple TLS docs:
/// https://developer.apple.com/documentation/security/preventing-insecure-network-connections
private final class PinnedAnchorsDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    private let clientIdentity: SecIdentity
    private let anchors: [SecCertificate]

    init(clientIdentity: SecIdentity, anchors: [SecCertificate]) {
        self.clientIdentity = clientIdentity
        self.anchors = anchors
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        switch method {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            SecTrustSetAnchorCertificates(serverTrust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(serverTrust, true)
            var evalError: CFError?
            if SecTrustEvaluateWithError(serverTrust, &evalError) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            let credential = URLCredential(
                identity: clientIdentity, certificates: nil, persistence: .forSession
            )
            completionHandler(.useCredential, credential)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Errors

/// Errors raised when constructing a ``KeychainTLSProvider``.
public enum TLSProviderError: Error, CustomStringConvertible {
    /// The client certificate PEM/DER could not be parsed.
    case invalidClientCertificate
    /// The private key PEM/DER could not be parsed.
    case invalidPrivateKey(CFError?)
    /// The CA certificate PEM/DER could not be parsed.
    case invalidCACertificate
    /// A Keychain operation returned a non-success status.
    case keychainError(OSStatus)
    /// Could not find an identity pairing cert + key in the Keychain.
    case identityNotFound(OSStatus)

    /// The `SecIdentity` returned from the Keychain carries a
    /// private key that doesn't match the certificate's public
    /// key. Detected via a sign-then-verify round-trip — see
    /// `KeychainTLSProvider.verifyIdentityPairing`.
    case invalidIdentity(String)

    public var description: String {
        switch self {
        case .invalidClientCertificate:
            "Failed to parse client certificate data"
        case .invalidPrivateKey(let error):
            "Failed to parse private key: \(error?.localizedDescription ?? "unknown")"
        case .invalidCACertificate:
            "Failed to parse CA certificate data"
        case .keychainError(let status):
            "Keychain operation failed with OSStatus \(status)"
        case .identityNotFound(let status):
            "SecIdentity not found after import (OSStatus \(status))"
        case .invalidIdentity(let reason):
            "TLS identity failed cert/key pairing verification: \(reason)"
        }
    }
}
