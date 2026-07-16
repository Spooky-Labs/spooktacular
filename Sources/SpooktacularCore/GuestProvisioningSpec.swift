import Foundation

/// Describes the account and setup preferences to apply to a fresh macOS
/// guest via `VZMacGuestProvisioningOptions` on first boot after restore.
///
/// Foundation-only domain value type; the mapping to the Virtualization
/// framework type lives in `SpooktacularInfrastructureApple` so this module
/// stays framework-free.
public struct GuestProvisioningSpec: Sendable, Equatable {
    /// The account's full (display) name.
    public var fullName: String
    /// The short login name (e.g. `runner`).
    public var username: String
    /// The account password. Ephemeral, generated per-VM.
    public var password: String
    /// Whether the guest auto-logs-in the account at startup. Defaults to `true`.
    public var logsInAutomatically: Bool
    /// Whether the guest enables Remote Login (SSH). Defaults to `false`.
    public var enablesRemoteLogin: Bool

    /// Creates a provisioning spec.
    /// - Parameters:
    ///   - fullName: The account's full (display) name.
    ///   - username: The short login name.
    ///   - password: The ephemeral account password.
    ///   - logsInAutomatically: Whether to auto-login at startup. Defaults to `true`.
    ///   - enablesRemoteLogin: Whether to enable SSH. Defaults to `false`.
    public init(
        fullName: String,
        username: String,
        password: String,
        logsInAutomatically: Bool = true,
        enablesRemoteLogin: Bool = false
    ) {
        self.fullName = fullName
        self.username = username
        self.password = password
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// Returns the spec unchanged if valid; otherwise throws.
    ///
    /// - Throws: ``GuestProvisioningError`` when the username is empty or the
    ///   password is shorter than the 8-character minimum.
    public func validated() throws -> GuestProvisioningSpec {
        guard !username.isEmpty else { throw GuestProvisioningError.emptyUsername }
        guard password.count >= 8 else { throw GuestProvisioningError.passwordTooShort }
        return self
    }
}

/// Errors from validating a ``GuestProvisioningSpec``.
public enum GuestProvisioningError: Error, Equatable {
    /// The username was empty.
    case emptyUsername
    /// The password was shorter than the 8-character minimum.
    case passwordTooShort
}
