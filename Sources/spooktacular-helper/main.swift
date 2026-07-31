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

/// Serves the helper contract: one privileged verb, plus a version probe.
///
/// The verb count is the point. This process runs as root, so every method it
/// exposes is attack surface, and it should expose exactly the privileged
/// operations the app actually performs — which is one: writing the
/// provisioner into a base image. Requests run on a serial queue because
/// disk-image mounts must not interleave.
final class HelperService: NSObject, SpooktacularHelperXPC {

    private let queue = DispatchQueue(label: "com.spooktacular.app.helper.work")

    /// Validates a base-image path handed over by the app.
    ///
    /// The helper runs as **root**, so it cannot recompute the calling
    /// user's `~/.spooktacular` to compare against — root's home is
    /// `/var/root`. Validation is therefore structural: the path must be
    /// absolute, must sit inside a base-image cache directory, must name
    /// the base image itself, and must contain no traversal. Combined
    /// with the code-signing requirement pinning the peer to this app,
    /// that keeps the verb from being turned into an
    /// arbitrary-file-write primitive.
    private func validatedBaseImageURL(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let components = url.pathComponents
        guard url.path.hasPrefix("/"),
              !path.contains(".."),
              url.lastPathComponent == "base.asif",
              components.contains(".spooktacular"),
              components.contains("cache"),
              components.contains("base"),
              FileManager.default.fileExists(atPath: url.path) else {
            throw HelperServiceError.notABaseImage(path)
        }
        return url
    }

    func installProvisionerIntoBaseImage(
        baseImagePath: String,
        reply: @escaping (NSError?) -> Void
    ) {
        queue.async {
            do {
                let imageURL = try self.validatedBaseImageURL(baseImagePath)
                guard let assets = ProvisionerAssets.locate() else {
                    throw HelperServiceError.assetsMissing
                }
                try DiskInjector.installProvisionerDaemon(
                    intoDiskImageAt: imageURL,
                    plist: assets.plist,
                    runner: assets.runner,
                    signal: assets.signal,
                    privileged: DirectPrivilegedFileOps()
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
    case notABaseImage(String)
    case assetsMissing

    var errorDescription: String? {
        switch self {
        case .notAVMBundle(let path):
            "Refusing to operate on '\(path)' — not a .vm bundle."
        case .notABaseImage(let path):
            "Refusing to operate on '\(path)' — not a base image in the Spooktacular cache."
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
