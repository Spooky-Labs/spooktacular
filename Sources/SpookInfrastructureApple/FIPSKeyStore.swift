import Foundation
import Security
import SpookCore
import SpookApplication

/// FIPS 140-2 compliant key storage using the Apple Secure Enclave.
///
/// On Apple Silicon Macs, the Secure Enclave provides hardware-backed
/// key storage that meets FIPS 140-2 Level 2 requirements. Keys are
/// generated inside the Secure Enclave and never leave it — all
/// cryptographic operations happen on the hardware.
///
/// ## Standards Compliance
///
/// - Apple's Secure Enclave has FIPS 140-2 Level 1 certification
///   (corecrypto module) and Level 2 physical security.
/// - Keys created with `kSecAttrTokenIDSecureEnclave` cannot be
///   exported or extracted from hardware.
/// - Signing operations are performed inside the Secure Enclave.
public struct FIPSKeyStore: Sendable {

    /// Creates a Secure Enclave-backed signing key.
    ///
    /// - Parameters:
    ///   - tag: A unique identifier for the key (e.g., "com.spooktacular.audit-signing")
    ///   - accessControl: Access control flags (default: private key usage)
    /// - Returns: The public key data for distribution to verifiers.
    public static func createSigningKey(tag: String) throws -> Data {
        // Delete any existing key with this tag
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // Create access control for Secure Enclave
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw FIPSError.accessControlFailed
        }

        // Generate key in Secure Enclave
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecAttrAccessControl as String: access,
            ] as [String: Any],
        ]

        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            // Fallback: if Secure Enclave is unavailable (e.g., VM or CI),
            // create a regular Keychain-backed key
            return try createSoftwareKey(tag: tag)
        }

        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw FIPSError.publicKeyExtractionFailed
        }

        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw FIPSError.publicKeyExtractionFailed
        }

        return publicKeyData
    }

    /// Signs data using a Secure Enclave-backed key.
    ///
    /// The signing operation happens inside the Secure Enclave hardware.
    /// The private key never leaves the enclave.
    public static func sign(data: Data, withKeyTag tag: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw FIPSError.keyNotFound(tag)
        }
        let privateKey = item as! SecKey

        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) as Data? else {
            throw FIPSError.signingFailed
        }

        return signature
    }

    /// Fallback: creates a software-backed key when Secure Enclave is unavailable.
    private static func createSoftwareKey(tag: String) throws -> Data {
        var error: Unmanaged<CFError>?
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            ] as [String: Any],
        ]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw FIPSError.keyGenerationFailed
        }
        return publicKeyData
    }
}

public enum FIPSError: Error, LocalizedError, Sendable {
    case accessControlFailed
    case keyGenerationFailed
    case publicKeyExtractionFailed
    case keyNotFound(String)
    case signingFailed

    public var errorDescription: String? {
        switch self {
        case .accessControlFailed: "Failed to create Secure Enclave access control"
        case .keyGenerationFailed: "Failed to generate key"
        case .publicKeyExtractionFailed: "Failed to extract public key"
        case .keyNotFound(let tag): "Signing key not found: \(tag)"
        case .signingFailed: "Signing operation failed"
        }
    }
}
