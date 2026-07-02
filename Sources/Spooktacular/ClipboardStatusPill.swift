import SwiftUI
import SpooktacularKit

/// Toolbar pill that renders the guest's SPICE clipboard
/// state with a filled `clipboard` SF Symbol tinted by the
/// current ``SpiceClipboardState``.
///
/// Matches the HIG pattern used by the Copy-IP button
/// elsewhere in the workspace toolbar — glass button, label
/// + system image, tooltip for the detail — so the new
/// affordance reads as first-class toolbar content rather
/// than an afterthought.
struct ClipboardStatusPill: View {
    let snapshot: SpiceStatusSnapshot

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(tint)
            .help(tooltip)
            .accessibilityLabel(Text("Clipboard: \(accessibilityLabel)"))
    }

    // MARK: - Rendering

    private var title: String {
        switch snapshot.state {
        case .notStarted: "Clipboard"
        case .connecting: "Clipboard…"
        case .connected:  "Clipboard"
        case .failed:     "Clipboard"
        }
    }

    private var symbol: String {
        switch snapshot.state {
        case .notStarted:  "clipboard"
        case .connecting:  "clipboard.fill"
        case .connected:   "clipboard.fill"
        case .failed:      "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch snapshot.state {
        case .notStarted: .secondary
        case .connecting: .orange
        case .connected:  .green
        case .failed:     .red
        }
    }

    private var tooltip: String {
        switch snapshot.state {
        case .notStarted:
            return "Clipboard sharing is not active. Install Spooktacular Guest Tools in the VM to enable it."
        case .connecting:
            return "Negotiating SPICE clipboard capabilities with the guest…"
        case .connected:
            return "Clipboard is bridged between host and guest via SPICE vd_agent."
        case .failed:
            return snapshot.message ?? "Clipboard bridge failed."
        }
    }

    private var accessibilityLabel: String {
        switch snapshot.state {
        case .notStarted: "not active"
        case .connecting: "connecting"
        case .connected:  "shared"
        case .failed:     "failed"
        }
    }
}
