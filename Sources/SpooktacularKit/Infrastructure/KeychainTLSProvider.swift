import Foundation
import Security

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
        let certData = try Data(contentsOf: URL(fileURLWithPath: certPath))
        let keyData  = try Data(contentsOf: URL(fileURLWithPath: keyPath))
        let caData   = try Data(contentsOf: URL(fileURLWithPath: caPath))

        // Import client certificate + key into a PKCS #12 identity.
        let identity = try Self.importIdentity(certDER: Self.decodePEM(certData),
                                               keyDER: Self.decodePEM(keyData))

        guard let caCert = SecCertificateCreateWithData(nil, Self.decodePEM(caData) as CFData) else {
            throw TLSProviderError.invalidCACertificate
        }

        self.init(clientIdentity: identity, trustedCA: caCert)
    }

    // MARK: - TLSIdentityProvider

    /// Returns a `URLSession` whose delegate handles mTLS challenges.
    public func configuredSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
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

    /// Imports a DER-encoded certificate and private key into a `SecIdentity`.
    private static func importIdentity(certDER: Data, keyDER: Data) throws -> SecIdentity {
        // Create the certificate.
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw TLSProviderError.invalidClientCertificate
        }

        // Import the private key.
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]

        var keyError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateWithData(keyDER as CFData,
                                                    keyAttributes as CFDictionary,
                                                    &keyError) else {
            throw TLSProviderError.invalidPrivateKey(keyError?.takeRetainedValue())
        }

        // Add both to the Keychain so SecIdentityCreate can find the pair.
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]
        SecItemDelete(certAddQuery as CFDictionary) // remove stale entry
        let certStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw TLSProviderError.keychainError(certStatus)
        }

        let keyAddQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
        ]
        SecItemDelete(keyAddQuery as CFDictionary) // remove stale entry
        let keyStatus = SecItemAdd(keyAddQuery as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
            throw TLSProviderError.keychainError(keyStatus)
        }

        // Retrieve the identity that pairs cert + key.
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
        ]
        var identityRef: CFTypeRef?
        let identityStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityRef)
        guard identityStatus == errSecSuccess, let identity = identityRef else {
            throw TLSProviderError.identityNotFound(identityStatus)
        }

        // swiftlint:disable:next force_cast
        return identity as! SecIdentity
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
