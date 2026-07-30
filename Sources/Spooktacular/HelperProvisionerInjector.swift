import Foundation
import ServiceManagement
import SpooktacularKit

/// Injects the provisioner into a base image through the approved
/// SMAppService helper, so the GUI never needs to be root.
///
/// Building a base image is unprivileged except for one step: writing
/// the `root:wheel` LaunchDaemon onto the guest's Data volume. This
/// injector hands exactly that step to the helper daemon the user
/// approved once in System Settings — which is what makes "install the
/// app, create a VM, it works" true without a terminal.
///
/// If the app already runs as root (an EC2 Mac service, or the app
/// launched under `sudo`), it injects directly instead of asking a
/// daemon to do what it can already do itself.
struct HelperProvisionerInjector: ProvisionerInjecting {

    /// The helper client to route privileged work through.
    private let helper: PrivilegedHelper

    /// Fallback used when this process is already root.
    private let direct = DirectProvisionerInjector()

    /// Creates an injector.
    ///
    /// - Parameter helper: The app's helper client.
    init(helper: PrivilegedHelper) {
        self.helper = helper
    }

    /// `true` when this process can do privileged file work itself.
    private var isRoot: Bool { getuid() == 0 }

    func preflight() async throws {
        if isRoot {
            try await direct.preflight()
            return
        }
        let status = await MainActor.run { helper.status }
        switch status {
        case .enabled:
            return
        case .requiresApproval:
            throw HelperProvisionerInjectorError.awaitingApproval
        case .notRegistered, .notFound:
            throw HelperProvisionerInjectorError.notRegistered
        @unknown default:
            throw HelperProvisionerInjectorError.notRegistered
        }
    }

    func injectProvisioner(intoDiskImageAt url: URL) async throws {
        if isRoot {
            try await direct.injectProvisioner(intoDiskImageAt: url)
            return
        }
        try await helper.installProvisionerIntoBaseImage(baseImageURL: url)
    }
}

/// Failures raised before handing privileged work to the helper.
enum HelperProvisionerInjectorError: Error, LocalizedError {

    /// The helper is registered but an admin has not approved it yet.
    case awaitingApproval

    /// The helper has not been registered with the system.
    case notRegistered

    var errorDescription: String? {
        switch self {
        case .awaitingApproval:
            "Spooktacular's privileged helper is waiting for approval."
        case .notRegistered:
            "Spooktacular's privileged helper is not enabled."
        }
    }

    var recoverySuggestion: String? {
        "Approve Spooktacular in System Settings → General → Login Items & Extensions, then create the VM again. Only the first macOS VM needs this — it builds the shared base image that every later VM reuses. Alternatively run `sudo spook create …` once in Terminal."
    }
}
