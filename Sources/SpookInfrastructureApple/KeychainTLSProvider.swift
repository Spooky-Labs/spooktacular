import Foundation
import SpookCore
import SpookApplication
import Security
import CryptoKit

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
public final class KeychainTLSProvider: NSObject, TLSIdentityProvider, URLSessionDelegate, @unchecked Sendable {

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
        // A mismatched dynamic type would crash `as!`, which on a
        // first-run path that handles user-supplied cert/key bytes
        // is a denial-of-service footgun. Surface the confusion as a
        // typed error so callers can alert instead.
        guard CFGetTypeID(identity) == SecIdentityGetTypeID() else {
            throw TLSProviderError.identityNotFound(identityStatus)
        }
        return identity as! SecIdentity  // now guarded by CFGetTypeID
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
        }
    }
}
