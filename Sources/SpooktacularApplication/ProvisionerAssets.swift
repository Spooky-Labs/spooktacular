import Foundation

/// Locates the bundled provisioner LaunchDaemon assets — the plist and its
/// runner script — that `DiskInjector.installProvisionerDaemon` writes into a
/// guest image.
///
/// Mirrors `AppBundleBootstrapTemplate.locateGuestToolsBundle()`: it searches
/// the app bundle's resources (where `build-app.sh` stages
/// `Resources/SpookProvisioner/`), tolerating absence in a plain `swift test`
/// context by returning `nil`.
public enum ProvisionerAssets {
    /// The bundled provisioner plist file name.
    public static let plistFileName = "com.spookylabs.spooktacular.provisioner.plist"
    /// The bundled provisioner runner-script file name.
    public static let runnerFileName = "spook-provision-runner.sh"

    /// Returns the URLs of the provisioner plist and runner script, or `nil`
    /// when they aren't present (e.g. a dev `swift build` without `build-app.sh`).
    public static func locate() -> (plist: URL, runner: URL)? {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        // Directories that may hold `Resources/SpookProvisioner/`.
        var roots: [URL] = []
        if let override = env["SPOOKTACULAR_PROVISIONER_DIR"] {
            roots.append(URL(fileURLWithPath: override))
        }
        roots.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/SpookProvisioner")
        )
        if let resourceURL = Bundle.main.resourceURL {
            roots.append(resourceURL.appendingPathComponent("SpookProvisioner"))
        }
        if let exe = Bundle.main.executableURL {
            roots.append(
                exe.deletingLastPathComponent().appendingPathComponent("SpookProvisioner")
            )
        }

        for root in roots {
            let plist = root.appendingPathComponent(plistFileName)
            let runner = root.appendingPathComponent(runnerFileName)
            if fm.fileExists(atPath: plist.path) && fm.fileExists(atPath: runner.path) {
                return (plist, runner)
            }
        }
        return nil
    }
}
