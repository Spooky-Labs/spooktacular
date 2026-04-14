import Foundation
import SpookCore
import SpookApplication
import CryptoKit

/// Concrete ``HMACProvider`` using Apple's CryptoKit.
///
/// This is the production implementation for webhook signature
/// verification and any other HMAC-SHA256 needs.
public struct CryptoKitHMACProvider: HMACProvider {
    public init() {}

    public func hmacSHA256(body: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
