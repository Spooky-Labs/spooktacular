import Foundation
import Security
import Virtualization
import SpooktacularCore

/// Generates ephemeral credentials for guest provisioning.
public enum EphemeralCredential {
    /// Returns a random alphanumeric password of the given length using the
    /// system CSPRNG.
    ///
    /// The alphabet is alphanumeric-only (and omits visually ambiguous
    /// characters) to avoid shell/quoting hazards when the value flows through
    /// `first-boot.sh` on the guest.
    ///
    /// - Parameter length: The password length. Defaults to 24.
    public static func generatePassword(length: Int = 24) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}

/// Maps a domain ``GuestProvisioningSpec`` onto the Virtualization framework's
/// `VZMacGuestProvisioningOptions` (macOS 27+).
///
/// - Parameter spec: The provisioning spec to translate.
/// - Returns: A configured `VZMacGuestProvisioningOptions`.
@available(macOS 27, *)
public func makeGuestProvisioningOptions(
    from spec: GuestProvisioningSpec
) -> VZMacGuestProvisioningOptions {
    let opts = VZMacGuestProvisioningOptions()
    opts.fullName = spec.fullName
    opts.username = spec.username
    opts.password = spec.password
    opts.logsInAutomatically = spec.logsInAutomatically
    opts.enablesRemoteLogin = spec.enablesRemoteLogin
    return opts
}
