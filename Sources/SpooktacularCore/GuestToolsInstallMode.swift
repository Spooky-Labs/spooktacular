import Foundation

/// Two-way user control for installing
/// `Spooktacular Guest Tools.app` inside a macOS guest VM.
///
/// Selected at VM-create time via ``CreateVMSheet`` or the
/// CLI's `spook create`. The creation pipeline reads this and
/// decides whether to `ditto` the `.app` bundle onto the
/// guest's `/Applications/` (``installed``) or leave the
/// guest completely untouched (``disabled``).
///
/// Launch-at-login is **not** a host-side decision. Once
/// Guest Tools opens inside the guest, its menu-bar UI
/// exposes a per-user Launch-at-Login toggle backed by
/// `SMAppService.mainApp` — the Apple-sanctioned
/// login-item API that runs in the user's own launchd
/// session, requires no admin privilege, and is visible in
/// System Settings → General → Login Items. This keeps the
/// host install path fully unprivileged: no `osascript`
/// admin prompt, no `root:wheel` `/Library/LaunchAgents/`
/// plist.
///
/// Operators who build "pristine macOS reference images"
/// for CI or golden-image work choose ``disabled`` — no
/// Guest Tools overhead at all. Users running the remote-
/// desktop / VDI use case choose ``installed``, open Guest
/// Tools once from `/Applications/`, and flip the toggle.
public enum GuestToolsInstallMode: String, Codable, Sendable, CaseIterable {
    /// No guest tools are installed. The VM boots as a
    /// pristine Apple-provided macOS image; host-side
    /// clipboard-sharing configuration (the
    /// `VZSpiceAgentPortAttachment` port) remains attached
    /// but idle on the guest side.
    case disabled

    /// `Spooktacular Guest Tools.app` is copied into the
    /// guest's `/Applications/` directory. The user opens
    /// the app themselves from Launchpad / Finder on first
    /// login; inside the app, a menu-bar "Launch at Login"
    /// toggle registers a per-user `SMAppService.mainApp`
    /// login item so subsequent logins auto-start the
    /// clipboard bridge.
    case installed

    /// Whether this mode requires the `.app` bundle to be
    /// ditto-ed onto the guest at provisioning time.
    public var installsAppBundle: Bool {
        self != .disabled
    }

    /// Display name for the picker. One-line user-facing
    /// string — no em-dashes or parentheticals so it renders
    /// cleanly in a SwiftUI `Picker` row.
    public var displayName: String {
        switch self {
        case .disabled:  "Don't install"
        case .installed: "Install Guest Tools"
        }
    }

    /// Longer help text suitable for a footer or tooltip.
    public var helpText: String {
        switch self {
        case .disabled:
            return "No helper app is added to the VM. Host clipboard sharing and the guest-agent HTTP API remain unavailable until you install Guest Tools manually."
        case .installed:
            return "Spooktacular Guest Tools appears in /Applications inside the VM. Open it once to activate the SPICE clipboard bridge; use its menu-bar Launch-at-Login toggle to start it automatically on subsequent logins."
        }
    }
}
