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
