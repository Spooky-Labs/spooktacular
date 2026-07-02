import Foundation
import AppKit
import os

/// Installs / uninstalls the Spooktacular provisioner
/// LaunchDaemon via the bundled `Spooktacular Provisioner.pkg`
/// opened in `Installer.app`.
///
/// ## Why a pkg, not `SMAppService.daemon`
///
/// Both the Spooktacular host app and the nested Guest Tools
/// app are sandboxed. On macOS 14.4+, Apple forbids a
/// sandboxed app from registering a LaunchDaemon via
/// `SMAppService.daemon(plistName:).register()` unless the
/// daemon itself is a sandboxed Mach-O binary. Our runner is
/// a bash script that needs to `mount_virtiofs` and exec
/// arbitrary user scripts as root — it cannot carry an
/// `app-sandbox` entitlement (entitlements apply to Mach-O
/// binaries, not scripts), so the SMAppService path returns
/// `SMAppServiceErrorDomain 1 / "Operation not permitted"`.
///
/// Apple's sanctioned alternative for "sandboxed app installs
/// a privileged helper" is a signed `.pkg` that
/// `Installer.app` (a system-privileged app) unpacks:
/// `NSWorkspace.open(pkgURL)` is allowed from within the
/// sandbox, and the rest happens as root inside Installer.app.
///
/// Trade-off vs. SMAppService: the user sees the standard
/// macOS Installer wizard and types their admin password once,
/// instead of flipping a toggle in System Settings → Login
/// Items & Extensions. One password, one time, per guest VM.
///
/// ## Install targets
///
/// After the user completes the wizard, the pkg's postinstall
/// places:
///
/// - `/Library/LaunchDaemons/com.spookylabs.spooktacular.provisioner.plist`
/// - `/usr/local/libexec/spook-provision-runner.sh`
///
/// — both owned root:wheel, and bootstraps the daemon into
/// the system launchd domain so it fires on first boot without
/// a reboot.
enum ProvisionerInstaller {

    /// The LaunchDaemon label — must match the `Label` key
    /// in the bundled plist and the postinstall script's
    /// `launchctl bootstrap` target.
    static let daemonLabel = "com.spookylabs.spooktacular.provisioner"

    /// Absolute path where the pkg's postinstall installs the
    /// plist. Existence of this file is the single source of
    /// truth for "is the provisioner installed?" — mirrors the
    /// `SMAppService.isEnabled` gate used in the earlier
    /// design.
    static let daemonPlistPath = "/Library/LaunchDaemons/\(daemonLabel).plist"

    /// Absolute path of the installed runner. Informational;
    /// install-state is decided by the plist alone.
    static let runnerPath = "/usr/local/libexec/spook-provision-runner.sh"

    /// Filename of the pkg inside Guest Tools' `Contents/Resources/`.
    /// `build-app.sh` produces it via `pkgbuild`; must match
    /// the pkg-output path there.
    private static let pkgResourceName = "Spooktacular Provisioner"
    private static let pkgResourceExtension = "pkg"

    // MARK: - Public API

    /// `true` when the LaunchDaemon plist exists at its install
    /// target — the only reliable signal we have for "the pkg
    /// has been run" without asking launchctl directly (a
    /// sandboxed query we'd rather avoid).
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlistPath)
    }

    /// Placeholder that matches the shape of the earlier
    /// `SMAppService` API surface. The pkg flow has no "waiting
    /// on user approval" state — Installer.app either finishes
    /// or it doesn't.
    static var requiresUserApproval: Bool { false }

    /// Menu action: opens `Spooktacular Provisioner.pkg` in
    /// Installer.app. The user clicks through the wizard,
    /// enters their admin password once, and the pkg's
    /// postinstall registers the daemon.
    ///
    /// `NSWorkspace.open` is allowed from within App Sandbox —
    /// we're merely handing a document to another app, not
    /// doing anything privileged ourselves.
    static func install(logger: Logger) throws {
        guard let pkgURL = Bundle.main.url(
            forResource: pkgResourceName,
            withExtension: pkgResourceExtension
        ) else {
            logger.error(
                "Provisioner pkg missing from Guest Tools bundle resources"
            )
            throw ProvisionerInstallerError.pkgNotFound
        }
        NSWorkspace.shared.open(pkgURL)
        logger.notice(
            "Opened provisioner pkg in Installer.app: \(pkgURL.path, privacy: .public)"
        )
    }

    /// Menu action: opens Terminal with an admin-privileged
    /// uninstall command queued up so the user can approve and
    /// run it. Sandbox forbids us from shelling out with sudo
    /// ourselves, so we have to delegate to Terminal the same
    /// way we delegate install to Installer.app.
    ///
    /// The command bootout's the daemon and removes both
    /// artifacts — symmetric with the pkg's postinstall.
    static func uninstall(logger: Logger) throws {
        let command = """
        sudo launchctl bootout system \(daemonPlistPath) 2>/dev/null; \
        sudo rm -f \(daemonPlistPath) \(runnerPath)
        """
        // AppleScript `tell "Terminal"` is blocked by the
        // sandbox, so we prompt the user to copy-paste instead
        // and open Terminal for them.
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        if let terminalURL = URL(string: "file:///System/Applications/Utilities/Terminal.app") {
            NSWorkspace.shared.open(terminalURL)
        }
        logger.notice("Uninstall command copied to clipboard; Terminal opened")
    }
}

/// Errors surfaced from the provisioner installer flow.
enum ProvisionerInstallerError: LocalizedError {
    /// The bundled `Spooktacular Provisioner.pkg` is missing
    /// from Guest Tools' `Contents/Resources/`. Usually means
    /// the app was built without `pkgbuild` finishing
    /// successfully — rebuild and try again.
    case pkgNotFound

    var errorDescription: String? {
        switch self {
        case .pkgNotFound:
            return "Provisioner installer package missing from Guest Tools resources. Rebuild the app."
        }
    }
}
