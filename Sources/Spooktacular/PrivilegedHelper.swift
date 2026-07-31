import Foundation
import os
import ServiceManagement
import SpooktacularInfrastructureApple

/// App-side client for the privileged helper daemon
/// (`spooktacular-helper`, see `HelperInterface`).
///
/// ## Lifecycle (Apple's SMAppService flow, macOS 13+)
///
/// 1. ``registerIfNeeded()`` calls `SMAppService.register()`. For a
///    LaunchDaemon the system does **not** bootstrap it until an admin
///    approves it in System Settings — `status` reports
///    `.requiresApproval` and ``openApprovalSettings()`` deep-links the
///    user there. Approval is one-time; launchd then bootstraps the
///    daemon on every boot (and approval can be revoked in Settings,
///    which this client surfaces as a non-`.enabled` status again).
/// 2. Once `.enabled`, ``installProvisionerDaemon(vmBundleURL:)`` /
///    ``installGuestTools(vmBundleURL:)`` perform the two root-only
///    guest-disk operations over a **code-signing-pinned** XPC
///    connection: the app requires the helper's identity, and the
///    helper's listener independently requires the app's — both pins
///    derived at runtime from each side's own signing team
///    (``HelperInterface/codeSigningRequirement(identifier:)``).
///
/// On EC2 Mac none of this runs: the CLI is already a root service.
@MainActor
final class PrivilegedHelper {

    static let shared = PrivilegedHelper()

    private let service = SMAppService.daemon(plistName: HelperInterface.plistName)

    /// Current authorization state, for the Create sheet's approval row.
    var status: SMAppService.Status { service.status }

    /// `true` when the daemon is approved and eligible to run.
    var isEnabled: Bool { service.status == .enabled }

    /// Registers the daemon (idempotent). After a first-time call the
    /// status is typically `.requiresApproval` until an admin flips the
    /// switch in System Settings.
    ///
    /// - Throws: `kSMErrorLaunchDeniedByUser` when the user has denied
    ///   the daemon, plus the other Service Management errors.
    func registerIfNeeded() throws {
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch let error as NSError
            where error.code == kSMErrorAlreadyRegistered {
            // Registered but pending approval / re-approval — fine.
        }
    }

    /// Deep-links System Settings → Login Items so the admin can
    /// approve (or re-approve) the daemon.
    func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Unregisters the daemon (Settings → clean removal).
    func unregister() throws {
        try service.unregister()
    }

    // MARK: - The two root operations

    /// Root-injects the provisioner LaunchDaemon into a shared base
    /// image via the helper.
    ///
    /// This is the call that makes the helper worth approving: it is the
    /// only privileged step of a base-image build, so routing it here
    /// lets the GUI build a base without the app itself being root.
    ///
    /// - Parameter baseImageURL: The staged `base.asif` to inject into.
    func installProvisionerIntoBaseImage(baseImageURL: URL) async throws {
        try await call { proxy, done in
            proxy.installProvisionerIntoBaseImage(baseImagePath: baseImageURL.path, reply: done)
        }
    }

    // MARK: - Connection plumbing

    /// One-shot pinned connection per call: builds the `.privileged`
    /// mach connection, pins the peer's signature, runs `body`, and
    /// invalidates. Provisioning is rare enough that connection reuse
    /// isn't worth the state.
    private func call(
        _ body: @escaping (SpooktacularHelperXPC, @escaping (NSError?) -> Void) -> Void
    ) async throws {
        guard let requirement = HelperInterface.codeSigningRequirement(
            identifier: "spooktacular-helper"
        ) else {
            throw PrivilegedHelperError.unsignedBuild
        }
        let connection = NSXPCConnection(
            machServiceName: HelperInterface.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: SpooktacularHelperXPC.self)
        connection.setCodeSigningRequirement(requirement)
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // `resultDelivered` guards the continuation: exactly one of
            // the error handler / reply may resume it.
            let resultDelivered = OSAllocatedUnfairLock(initialState: false)
            func finish(_ result: Result<Void, Error>) {
                let first = resultDelivered.withLock { delivered -> Bool in
                    if delivered { return false }
                    delivered = true
                    return true
                }
                guard first else { return }
                cont.resume(with: result)
            }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(error))
            }) as? SpooktacularHelperXPC else {
                finish(.failure(PrivilegedHelperError.badProxy))
                return
            }
            body(proxy) { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            }
        }
    }
}

/// App-side helper-client failures.
enum PrivilegedHelperError: Error, LocalizedError {
    /// The running app has no signing team — peers can't be pinned, so
    /// the client refuses to connect (matching the helper's refusal).
    case unsignedBuild
    /// The XPC proxy could not be cast to the contract protocol.
    case badProxy

    var errorDescription: String? {
        switch self {
        case .unsignedBuild:
            "This build isn't signed with a team identity, so the privileged helper can't be used. Use `sudo spook create …` instead."
        case .badProxy:
            "Could not create the XPC proxy for the privileged helper."
        }
    }
}
