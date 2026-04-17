import CryptoKit
import Foundation
import LocalAuthentication

/// Anything that can produce a compact 64-byte P-256 ECDSA
/// signature for a given payload.
///
/// This is the unified signing primitive for every piece of
/// Spooktacular cryptography that writes an authenticating
/// signature — break-glass tickets and Merkle audit tree heads
/// today, request-signing tomorrow. Two concrete
/// implementations exist:
///
/// - **SEP-bound** (production default): keys are generated
///   inside the macOS Secure Enclave and never leave it; every
///   `signature(for:)` call is a hardware operation inside the
///   SEP. See ``sepSigner(from:context:)``.
/// - **Software** (tests + non-SEP hosts): `P256.Signing.PrivateKey`
///   conforms directly. Key material is ordinary process memory;
///   use only when no Secure Enclave is available.
///
/// Consumers take `any P256Signer` and stay testable without
/// hardware.
public protocol P256Signer: Sendable {
    /// Returns the 64-byte `r ‖ s` raw representation of the
    /// P-256 ECDSA signature over `data`.
    func signature(for data: Data) throws -> Data

    /// The matching public key, for export / distribution.
    var publicKey: P256.Signing.PublicKey { get }
}

/// Software `P256.Signing.PrivateKey` as a signer — used by
/// tests and by the file-backed CLI fallback. Production code
/// should prefer ``sepSigner(from:context:)``.
extension P256.Signing.PrivateKey: P256Signer {
    public func signature(for data: Data) throws -> Data {
        let sig = try self.signature(for: data) as P256.Signing.ECDSASignature
        return sig.rawRepresentation
    }
}

// MARK: - Secure Enclave adapter

/// Wraps a `SecureEnclave.P256.Signing.PrivateKey` as a
/// ``P256Signer``. The key material never leaves the SEP —
/// every signing operation is an IPC to the Secure Enclave
/// Processor.
public struct SEPSigner: P256Signer {
    public let underlying: SecureEnclave.P256.Signing.PrivateKey
    public var publicKey: P256.Signing.PublicKey { underlying.publicKey }

    public init(_ underlying: SecureEnclave.P256.Signing.PrivateKey) {
        self.underlying = underlying
    }

    public func signature(for data: Data) throws -> Data {
        try underlying.signature(for: data).rawRepresentation
    }
}
