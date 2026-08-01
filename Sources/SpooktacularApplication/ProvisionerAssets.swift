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
    /// The bundled guest-side readiness reporter's file name.
    public static let signalFileName = "spook-signal"

    /// Returns the URLs of the provisioner plist and runner script, or `nil`
    /// when they aren't present (e.g. a dev `swift build` without `build-app.sh`).
    ///
    /// `signal` is the guest-side readiness reporter. It is optional: a base
    /// image built without it still provisions, it just leaves the host to
    /// read the first-boot logs instead of receiving an exit code. Making it
    /// non-optional would turn a missing convenience into a create failure.
    /// - Parameter environment: Process environment, injected for testability
    ///   the same way ``AdminPresenceGate/requirePresence(reason:environment:context:bypassVerifier:auditSink:metricsCounter:hostname:tenant:)``
    ///   takes it. A test exercising the override must pass it here rather
    ///   than call `setenv`: that mutates process-global state, and under
    ///   `swift test --parallel` it leaks into whatever else is running at the
    ///   time. That is exactly how "locate returns nil outside an app bundle"
    ///   came to fail in CI while passing locally — the two tests in that
    ///   suite were racing for one environment variable.
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (plist: URL, runner: URL, signal: URL?)? {
        let env = environment
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
                let signal = root.appendingPathComponent(signalFileName)
                return (
                    plist,
                    runner,
                    fm.fileExists(atPath: signal.path) ? signal : nil
                )
            }
        }
        return nil
    }
}
