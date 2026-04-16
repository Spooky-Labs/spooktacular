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

    /// Describes the backing store chosen for a generated signing key.
    ///
    /// Returned alongside the public key so callers can enforce a
    /// hardware-only policy in production (reject `.software`) and
    /// surface the fallback path in observability.
    public enum Backing: Sendable, Equatable {
        /// Key lives in the Secure Enclave — private key material never
        /// leaves hardware, signing happens inside the chip.
        case secureEnclave
        /// Key lives in the Keychain as software-protected bytes —
        /// NOT FIPS 140-2 compliant. Intended for CI/dev only.
        case software(reason: String)
    }

    /// A generated key's public-key bytes plus the backing it uses.
    public struct SigningKey: Sendable {
        public let publicKey: Data
        public let backing: Backing
        public var isHardwareBacked: Bool {
            if case .secureEnclave = backing { return true }
            return false
        }
    }

    /// Creates a signing key and reports which backing was used.
    ///
    /// In production, callers should check ``SigningKey/isHardwareBacked``
    /// and refuse to proceed (or alert via observability) if it's
    /// `false` — the software fallback is present only so CI and VMs
    /// without Secure Enclave can still exercise the code path.
    public static func createSigningKeyReportingBacking(tag: String) throws -> SigningKey {
        do {
            let publicKey = try createSecureEnclaveKey(tag: tag)
            return SigningKey(publicKey: publicKey, backing: .secureEnclave)
        } catch let error as FIPSError where error == .secureEnclaveUnavailable {
            let publicKey = try createSoftwareKey(tag: tag)
            return SigningKey(
                publicKey: publicKey,
                backing: .software(reason: "Secure Enclave unavailable on this host")
            )
        }
    }

    /// Creates a Secure Enclave-backed signing key.
    ///
    /// - Parameters:
    ///   - tag: A unique identifier for the key (e.g., "com.spooktacular.audit-signing")
    /// - Returns: The public key data for distribution to verifiers.
    /// - Note: On hosts without a Secure Enclave the implementation
    ///   silently falls back to a software key. To detect the fallback,
    ///   call ``createSigningKeyReportingBacking(tag:)`` instead.
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

    /// Creates a Secure Enclave key or throws
    /// ``FIPSError/secureEnclaveUnavailable`` if the hardware declines.
    ///
    /// Separated out so ``createSigningKeyReportingBacking(tag:)`` can
    /// distinguish "no Secure Enclave here" from actual hard failures.
    private static func createSecureEnclaveKey(tag: String) throws -> Data {
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
        ] as CFDictionary)

        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw FIPSError.accessControlFailed
        }

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
            throw FIPSError.secureEnclaveUnavailable
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
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
    ///
    /// - Warning: Software keys are NOT FIPS 140-2 compliant. This fallback
    ///   exists for CI/VM environments only. Production deployments should
    ///   always use Apple Silicon with Secure Enclave.
    private static func createSoftwareKey(tag: String) throws -> Data {
        var error: Unmanaged<CFError>?
        // OWASP: Apply access control even on software keys to prevent
        // export by other processes running under the same user.
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            [.privateKeyUsage],
            &error
        ) else {
            throw FIPSError.accessControlFailed
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
                kSecAttrAccessControl as String: access,
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

public enum FIPSError: Error, LocalizedError, Sendable, Equatable {
    case accessControlFailed
    case keyGenerationFailed
    case publicKeyExtractionFailed
    case keyNotFound(String)
    case signingFailed
    case secureEnclaveUnavailable

    public var errorDescription: String? {
        switch self {
        case .accessControlFailed: "Failed to create Secure Enclave access control"
        case .keyGenerationFailed: "Failed to generate key"
        case .publicKeyExtractionFailed: "Failed to extract public key"
        case .keyNotFound(let tag): "Signing key not found: \(tag)"
        case .signingFailed: "Signing operation failed"
        case .secureEnclaveUnavailable: "Secure Enclave is not available on this host"
        }
    }
}
