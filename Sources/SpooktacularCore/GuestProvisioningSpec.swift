import Foundation

/// Describes the account and setup preferences to apply to a fresh macOS
/// guest via `VZMacGuestProvisioningOptions` on first boot after restore.
///
/// Foundation-only domain value type; the mapping to the Virtualization
/// framework type lives in `SpooktacularInfrastructureApple` so this module
/// stays framework-free.
public struct GuestProvisioningSpec: Sendable, Equatable, Codable {
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

    /// The non-secret ``PendingProvisioning`` marker for this spec.
    ///
    /// Drops the password, keeping only the fields that are safe to
    /// persist in `metadata.json`. Written at create time so a
    /// deferred first boot (`spook start`) knows which account to
    /// provision; the password itself is stashed transiently in the
    /// login Keychain, never on disk. See ``PendingProvisioning``.
    public var pendingMarker: PendingProvisioning {
        PendingProvisioning(
            fullName: fullName,
            username: username,
            logsInAutomatically: logsInAutomatically,
            enablesRemoteLogin: enablesRemoteLogin
        )
    }
}

/// A **non-secret** record that a VM still needs native first-boot
/// provisioning (macOS 27 `VZMacGuestProvisioningOptions`) applied.
///
/// This is the on-disk half of the transient-password design: it is
/// persisted in `metadata.json` and carries only fields that are safe
/// to store in a plaintext, queryable artifact — the account's full
/// name and short username, plus the two boolean setup preferences.
/// The account **password is never stored here**. It lives only in the
/// macOS login Keychain (service `com.spooktacular.provisioning`, keyed
/// by the VM UUID), written at `create`, read at the first `start`, and
/// deleted after the first successful boot.
///
/// `spook start` (and the GUI's start) reconstitutes the full
/// ``GuestProvisioningSpec`` by pairing this marker with the
/// Keychain-held password via ``spec(password:)``, applies it on the
/// first boot, then clears both the marker and the Keychain item.
/// `nil` once provisioned, and for VMs that never need it (a runner VM
/// boots during `create`, so its spec is applied and discarded there).
public struct PendingProvisioning: Sendable, Codable, Equatable {

    /// The account's full (display) name.
    public var fullName: String

    /// The short login name (e.g. `admin`).
    public var username: String

    /// Whether the guest auto-logs-in the account at startup.
    public var logsInAutomatically: Bool

    /// Whether the guest enables Remote Login (SSH) on first boot.
    public var enablesRemoteLogin: Bool

    /// Creates a non-secret provisioning marker.
    /// - Parameters:
    ///   - fullName: The account's full (display) name.
    ///   - username: The short login name.
    ///   - logsInAutomatically: Whether to auto-login at startup.
    ///   - enablesRemoteLogin: Whether to enable SSH on first boot.
    public init(
        fullName: String,
        username: String,
        logsInAutomatically: Bool,
        enablesRemoteLogin: Bool
    ) {
        self.fullName = fullName
        self.username = username
        self.logsInAutomatically = logsInAutomatically
        self.enablesRemoteLogin = enablesRemoteLogin
    }

    /// Reconstitutes the full ``GuestProvisioningSpec`` by pairing this
    /// marker with the supplied password.
    ///
    /// The password is the value read back from the login Keychain at
    /// first-boot time — it lives in memory only for the duration of
    /// the boot and is never re-persisted to `metadata.json`.
    ///
    /// - Parameter password: The account password, sourced from the
    ///   Keychain (service `com.spooktacular.provisioning`).
    /// - Returns: A ``GuestProvisioningSpec`` combining this marker's
    ///   non-secret fields with `password`.
    public func spec(password: String) -> GuestProvisioningSpec {
        GuestProvisioningSpec(
            fullName: fullName,
            username: username,
            password: password,
            logsInAutomatically: logsInAutomatically,
            enablesRemoteLogin: enablesRemoteLogin
        )
    }
}

/// Errors from validating a ``GuestProvisioningSpec``.
public enum GuestProvisioningError: Error, Equatable {
    /// The username was empty.
    case emptyUsername
    /// The password was shorter than the 8-character minimum.
    case passwordTooShort
}
