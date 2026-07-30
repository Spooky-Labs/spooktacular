import Foundation
import SpooktacularApplication

/// Installs the provisioner LaunchDaemon into a guest disk image.
///
/// Building a base image is almost entirely unprivileged — creating the
/// ASIF image, running `VZMacOSInstaller`, and sealing the result all
/// run as the ordinary user. Exactly one step needs root: writing the
/// `root:wheel` LaunchDaemon onto the guest's Data volume.
///
/// Abstracting that single step lets the same builder serve both
/// deployment shapes. A root process (the EC2 Mac service, or
/// `sudo spook create`) injects directly; the sandboxed GUI hands the
/// work to its approved SMAppService helper over XPC, so a user who
/// approved the helper once never needs a terminal.
public protocol ProvisionerInjecting: Sendable {

    /// Fails fast when injection could not succeed.
    ///
    /// Called before the 10–20 minute install so a permissions problem
    /// surfaces in milliseconds rather than after the expensive work.
    func preflight() async throws

    /// Injects the provisioner into a guest disk image.
    ///
    /// - Parameter url: The disk image to inject into. Must be a
    ///   stopped, unbooted image.
    func injectProvisioner(intoDiskImageAt url: URL) async throws
}

/// Injects the provisioner in-process, as root.
///
/// Used by the CLI, which is already root on an EC2 Mac and asks for
/// `sudo` locally. The GUI uses its helper-backed counterpart instead.
public struct DirectProvisionerInjector: ProvisionerInjecting {

    /// Creates an injector.
    public init() {}

    public func preflight() async throws {
        guard ProvisionerAssets.locate() != nil else {
            throw BaseImageBuildError.provisionerAssetsMissing
        }
        do {
            try DirectPrivilegedFileOps().preflight()
        } catch {
            throw BaseImageBuildError.requiresRoot
        }
    }

    public func injectProvisioner(intoDiskImageAt url: URL) async throws {
        guard let assets = ProvisionerAssets.locate() else {
            throw BaseImageBuildError.provisionerAssetsMissing
        }
        try DiskInjector.installProvisionerDaemon(
            intoDiskImageAt: url,
            plist: assets.plist,
            runner: assets.runner,
            signal: assets.signal,
            privileged: DirectPrivilegedFileOps()
        )
    }
}
