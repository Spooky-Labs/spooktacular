import Foundation
import Security
@testable import SpooktacularInfrastructureApple

/// Failures raised while creating a ``TemporaryKeychain``.
enum TemporaryKeychainError: Error {
    /// `SecKeychainCreate` returned a non-success `OSStatus`.
    case creationFailed(OSStatus)
}

/// A throwaway keychain that exists for the lifetime of one test.
///
/// Keychain tests that use the developer's login keychain are flaky by
/// construction: `swift test --parallel` runs hundreds of tests in one
/// process, several of which touch the keychain, and a delete-then-add
/// pair can observe a stale view of that shared store and fail with
/// `errSecDuplicateItem`.
///
/// A temporary file-based keychain is the only workable isolation on
/// macOS. The data-protection keychain is a single per-user store that
/// cannot be duplicated for tests and can only be partitioned with a
/// keychain-access-group entitlement, which a SwiftPM test bundle does
/// not have. `SecKeychainCreate` is deprecated but is the only API that
/// creates a keychain — the same trade-off this project already accepts
/// for `SecKeychainOpen` on the System keychain.
///
/// The keychain is created **unlocked** and is deliberately *not* added
/// to the user's search list, so its items are invisible both to the
/// login keychain and to every other test in the process.
///
/// Mirrors `TempDirectory`: hold one for the duration of a test and let
/// `deinit` clean up.
///
/// - Note: Do not call `SecKeychainSetSettings` on ``reference``. It
///   returns `userCanceledErr` here and poisons every subsequent
///   `SecItem*` call; a freshly created keychain needs no adjustment.
final class TemporaryKeychain {

    /// The underlying keychain, used to scope `SecItem*` queries.
    let reference: SecKeychain

    private let directory: URL

    /// Creates an unlocked keychain in a unique temporary directory.
    ///
    /// - Throws: ``TemporaryKeychainError/creationFailed(_:)``.
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spook-keychain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("provisioning.keychain").path
        let password = Array(UUID().uuidString.utf8)
        var created: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else {
            throw TemporaryKeychainError.creationFailed(status)
        }
        reference = created
    }

    deinit {
        _ = SecKeychainDelete(reference)
        try? FileManager.default.removeItem(at: directory)
    }

    /// The store target that scopes every operation to this keychain.
    var target: ProvisioningPasswordStore.Target { .keychain(reference) }
}
