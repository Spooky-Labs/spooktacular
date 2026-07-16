import Foundation
import SpooktacularCore

/// Pure-data helpers for installing `Spooktacular Guest
/// Tools.app` into a macOS guest VM.
///
/// No bash scripts, no base64 encoding, no tar: the install
/// flow is "mount the guest's APFS data volume on the host,
/// `/usr/bin/ditto` the `.app` bundle in, unmount". That
/// logic lives in
/// ``SpooktacularInfrastructureApple/DiskInjector/installGuestTools(appBundle:into:)``;
/// this namespace is the source-of-truth for the bundle
/// filename and the host-side resolver.
///
/// Launch-at-login is owned by the Guest Tools app itself,
/// via its menu-bar `SMAppService.mainApp` toggle — so
/// nothing here writes a `/Library/LaunchAgents/` plist and
/// the host never has to step up to root to chown it.
public enum AppBundleBootstrapTemplate {

    /// The `.app` bundle file name as it appears inside the
    /// host's Spooktacular.app AND on the guest's
    /// `/Applications/`. Single source of truth so callers
    /// can't drift.
    public static let bundleFileName = "Spooktacular Guest Tools.app"

    /// Guest-side install path — always
    /// `/Applications/Spooktacular Guest Tools.app`.
    public static let installedAppPath = "/Applications/\(bundleFileName)"

    /// Resolves the bundled `Spooktacular Guest Tools.app` on
    /// the host filesystem. Discovery order:
    ///
    /// 1. `$SPOOKTACULAR_GUEST_TOOLS_BUNDLE` environment
    ///    override — for tests and dev iteration.
    /// 2. `<Bundle.main>/Contents/Applications/<bundle-name>`
    ///    — the path `build-app.sh` places it at inside the
    ///    main host app's `.app` wrapper.
    /// 3. Sibling of the currently-running executable — the
    ///    `.build/<config>/` layout during `swift build`
    ///    developer iteration.
    ///
    /// Uses Apple's `Bundle.main.bundleURL` /
    /// `Bundle.main.executableURL` primitives so resolution
    /// works through symlinks and stripped `argv[0]` —
    /// matches how Apple's own tooling locates bundled
    /// helpers.
    ///
    /// Returns `nil` if none resolve; callers treat that as
    /// "no guest-tools install, skip the step".
    public static func locateGuestToolsBundle() -> URL? {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default

        if let override = env["SPOOKTACULAR_GUEST_TOOLS_BUNDLE"] {
            let url = URL(fileURLWithPath: override)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }

        var candidates: [URL] = [
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Applications")
                .appendingPathComponent(bundleFileName),
        ]
        if let exe = Bundle.main.executableURL {
            candidates.append(
                exe.deletingLastPathComponent()
                    .appendingPathComponent(bundleFileName)
            )
        }

        return candidates.first { fm.fileExists(atPath: $0.path) }
    }
}
