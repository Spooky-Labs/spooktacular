import SwiftUI
import AppKit
import SpiceClipboardAgent

/// The dropdown rendered when the user clicks the menu-bar
/// icon. Shows the clipboard-bridge status, a Launch-at-Login
/// toggle, and Restart/About/Quit actions.
struct MenuContent: View {
    @Bindable var controller: AgentController

    var body: some View {
        Group {
            Text(controller.status.humanDescription)
                .font(.caption)
                .task {
                    // User may have flipped the approval
                    // toggle in System Settings while Guest
                    // Tools was running. Every menu open is a
                    // cheap chance to sync.
                    controller.refreshProvisioningStatus()
                }

            Divider()

            Toggle(
                "Launch at Login",
                isOn: $controller.launchAtLoginEnabled
            )
            if let loginError = controller.loginItemError {
                Text(loginError)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("Restart Clipboard Bridge") {
                controller.stop()
                controller.start()
            }

            Divider()

            // Provisioning section. When the daemon isn't yet
            // installed, the menu opens the bundled pkg in
            // Installer.app for a one-time admin-password
            // install. When it is, we show a status line and
            // an uninstall entry that hands off to Terminal
            // for the symmetric sudo removal.
            if controller.provisionerInstalled {
                Text("Provisioning: enabled")
                    .font(.caption)

                Button("Disable Provisioning…") {
                    controller.disableProvisioning()
                }
            } else {
                Text("Provisioning: not enabled")
                    .font(.caption)
                Button("Enable Provisioning…") {
                    controller.enableProvisioning()
                }
                Text("Opens a signed installer (one admin password) that registers the Spooktacular provisioner daemon so the host can run first-boot / template scripts in this VM.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
            if let err = controller.provisionerError {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider()

            Button("About Spooktacular Guest Tools") {
                if let url = URL(string: "https://spookylabs.ai") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

// MARK: - Status rendering

extension SpiceAgentStatus {
    /// SF Symbol representing the status for the menu-bar icon.
    var menuBarSymbol: String {
        switch self {
        case .notStarted: "clipboard"
        case .connecting: "clipboard.fill"
        case .connected:  "clipboard.fill"
        case .failed:     "exclamationmark.circle.fill"
        }
    }

    /// Tint applied to the menu-bar icon. Chosen to match the
    /// main app's status semantics (green = healthy, orange =
    /// in-flight, red = error, secondary = idle).
    var menuBarTint: Color {
        switch self {
        case .notStarted: .secondary
        case .connecting: .orange
        case .connected:  .green
        case .failed:     .red
        }
    }

    var humanDescription: String {
        switch self {
        case .notStarted:
            return "Clipboard bridge: not running"
        case .connecting:
            return "Clipboard bridge: connecting…"
        case .connected:
            return "Clipboard bridge: connected"
        case .failed(let error):
            return error.localizedDescription
        }
    }
}
