import Foundation
import Security

/// The XPC contract between `Spooktacular.app` and its privileged helper
/// daemon (`spooktacular-helper`, registered via
/// `SMAppService.daemon(plistName:)`).
///
/// ## Why this exists
///
/// Injecting the provisioner LaunchDaemon or Guest Tools into a guest
/// disk mounts the disk image — root-only. On EC2 Mac the CLI already
/// runs as a root service; locally, the sandboxed GUI escalates through
/// this helper instead: the admin approves the daemon **once** in
/// System Settings (Apple's `SMAppService` flow), after which the root
/// daemon services these two verbs over XPC.
///
/// ## Security posture
///
/// - **Two verbs, no general file API.** The helper takes only a VM
///   bundle path; provisioner/Guest Tools asset paths are derived from
///   the helper's **own** `Bundle.main` (it lives inside the signed
///   app bundle), so a client can never retarget the root process at
///   arbitrary files.
/// - **Both peers pin code signatures** — the app requires the daemon,
///   and the daemon's listener requires the app — using a designated
///   requirement built at runtime from the *caller's own* team
///   identifier (``codeSigningRequirement(identifier:)``). Never a PID
///   check, never a hardcoded team.
@objc public protocol SpooktacularHelperXPC {

    /// Injects the Spooktacular provisioner LaunchDaemon into the VM
    /// bundle's guest disk (mounts the disk; root-only).
    ///
    /// - Parameters:
    ///   - vmBundlePath: Absolute path to a `.vm` bundle directory.
    ///   - reply: `nil` on success, or the failure.
    func installProvisionerDaemon(
        vmBundlePath: String,
        reply: @escaping (NSError?) -> Void
    )

    /// Installs Spooktacular Guest Tools into the VM bundle's guest
    /// disk (mounts the disk; root-only).
    ///
    /// - Parameters:
    ///   - vmBundlePath: Absolute path to a `.vm` bundle directory.
    ///   - reply: `nil` on success, or the failure.
    func installGuestTools(
        vmBundlePath: String,
        reply: @escaping (NSError?) -> Void
    )

    /// Injects the provisioner LaunchDaemon into a **shared base
    /// image** in the base-image cache (mounts the image; root-only).
    ///
    /// This is the one privileged step of a base-image build, and the
    /// reason the GUI's helper exists: everything else — creating the
    /// ASIF image, running the installer, sealing the result — runs
    /// unprivileged, so routing just this call through the approved
    /// helper lets a GUI user build a base without a terminal.
    ///
    /// - Parameters:
    ///   - baseImagePath: Absolute path to a staged `base.asif` inside
    ///     the base-image cache. Validated by the helper.
    ///   - reply: `nil` on success, or the failure.
    func installProvisionerIntoBaseImage(
        baseImagePath: String,
        reply: @escaping (NSError?) -> Void
    )

    /// Version/handshake probe so the app can detect a stale helper
    /// after an app update (the approved daemon relaunches from the
    /// updated bundle on next boot, but not mid-session).
    func helperVersion(reply: @escaping (String) -> Void)
}

/// Shared constants + the peer-pinning requirement builder.
public enum HelperInterface {

    /// The mach service name the daemon's plist advertises under
    /// `MachServices` and the app connects to (`.privileged`).
    public static let machServiceName = "com.spooktacular.app.helper"

    /// The daemon plist's file name inside
    /// `Spooktacular.app/Contents/Library/LaunchDaemons/`.
    public static let plistName = "com.spooktacular.app.helper.plist"

    /// Protocol version, echoed by ``SpooktacularHelperXPC/helperVersion(reply:)``.
    public static let version = "1"

    /// Builds the designated-requirement string used to pin the XPC
    /// peer: same signing **team as the running process**, the given
    /// signing identifier, Apple-anchored.
    ///
    /// The team identifier is read from the caller's own signature via
    /// `SecCodeCopySelf` + `SecCodeCopySigningInformation`
    /// (`kSecCSSigningInformation`) — so dev builds pin the dev team
    /// and Developer ID builds pin the release team with no
    /// configuration. Returns `nil` for unsigned/ad-hoc processes
    /// (no stable team identity — Apple DTS: peers can't be securely
    /// identified without real signing), in which case callers must
    /// refuse to bridge rather than connect unpinned.
    ///
    /// - Parameter identifier: The peer's code-signing identifier
    ///   (bundle ID for the app; the executable name for the helper).
    public static func codeSigningRequirement(identifier: String) -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess,
              let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info = info as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty else { return nil }
        return #"anchor apple generic and identifier "\#(identifier)" and certificate leaf[subject.OU] = "\#(team)""#
    }
}
