import Foundation
import SpooktacularApplication
import SpooktacularInfrastructureApple

/// `spooktacular-helper` — the privileged daemon behind
/// `SMAppService.daemon(plistName:)`.
///
/// Lives at `Spooktacular.app/Contents/MacOS/spooktacular-helper`,
/// registered from the app and approved once by an admin in System
/// Settings → Login Items; launchd then bootstraps it as root on every
/// boot. It services exactly two root-only operations — provisioner
/// daemon injection and Guest Tools installation into a guest disk —
/// over an XPC connection whose peer is pinned by code signature.
/// Everything else about provisioning stays in the app (rootless).
///
/// Because this executable sits in `Contents/MacOS/`, its `Bundle.main`
/// resolves to the app bundle itself, so `ProvisionerAssets.locate()`
/// and `AppBundleBootstrapTemplate.locateGuestToolsBundle()` find the
/// same signed assets the app would — a connecting client never
/// supplies asset paths to a root process.

/// Serves the two-verb contract. Runs every request on a serial queue —
/// disk-image mounts must not interleave.
final class HelperService: NSObject, SpooktacularHelperXPC {

    private let queue = DispatchQueue(label: "com.spooktacular.app.helper.work")

    private func loadBundle(at path: String) throws -> VirtualMachineBundle {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension == "vm" else {
            throw HelperServiceError.notAVMBundle(path)
        }
        return try VirtualMachineBundle.load(from: url)
    }

    func installProvisionerDaemon(
        vmBundlePath: String,
        reply: @escaping (NSError?) -> Void
    ) {
        queue.async {
            do {
                let bundle = try self.loadBundle(at: vmBundlePath)
                guard let assets = ProvisionerAssets.locate() else {
                    throw HelperServiceError.assetsMissing
                }
                try DiskInjector.installProvisionerDaemon(
                    into: bundle,
                    plist: assets.plist,
                    runner: assets.runner,
                    privileged: DirectPrivilegedFileOps()
                )
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    func installGuestTools(
        vmBundlePath: String,
        reply: @escaping (NSError?) -> Void
    ) {
        queue.async {
            do {
                let bundle = try self.loadBundle(at: vmBundlePath)
                guard let guestTools = AppBundleBootstrapTemplate.locateGuestToolsBundle() else {
                    throw HelperServiceError.assetsMissing
                }
                try DiskInjector.installGuestTools(
                    appBundle: guestTools,
                    into: bundle
                )
                reply(nil)
            } catch {
                reply(error as NSError)
            }
        }
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(HelperInterface.version)
    }
}

/// Helper-local failures surfaced over XPC.
enum HelperServiceError: Error, LocalizedError {
    case notAVMBundle(String)
    case assetsMissing

    var errorDescription: String? {
        switch self {
        case .notAVMBundle(let path):
            "Refusing to operate on '\(path)' — not a .vm bundle."
        case .assetsMissing:
            "Provisioner/Guest Tools assets not found in the app bundle."
        }
    }
}

/// Accepts connections only from processes matching the pinned
/// requirement (the app's bundle identifier, same signing team as this
/// helper). An unsigned/ad-hoc build yields no requirement — refuse to
/// listen rather than accept unpinned peers (DTS: such peers cannot be
/// securely identified).
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {

    private let requirement: String

    init(requirement: String) {
        self.requirement = requirement
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: SpooktacularHelperXPC.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}

// A privileged daemon must actually be privileged: refuse to serve
// otherwise (per Apple DTS guidance for SMAppService daemons).
guard getuid() == 0 else {
    FileHandle.standardError.write(Data("spooktacular-helper must run as root (launchd daemon).\n".utf8))
    exit(EXIT_FAILURE)
}

guard let requirement = HelperInterface.codeSigningRequirement(
    identifier: "com.spooktacular.app"
) else {
    FileHandle.standardError.write(Data("spooktacular-helper: no signing team identity; refusing to accept unpinned XPC peers.\n".utf8))
    exit(EXIT_FAILURE)
}

let delegate = ListenerDelegate(requirement: requirement)
let listener = NSXPCListener(machServiceName: HelperInterface.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
