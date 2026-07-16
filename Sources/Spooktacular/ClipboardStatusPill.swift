import SwiftUI
import SFSymbolsKit
import SpooktacularKit

/// Toolbar pill that renders the guest's SPICE clipboard
/// state with a filled `clipboard` SF Symbol tinted by the
/// current ``SpiceClipboardState``.
///
/// A status indicator (not an action): the workspace toolbar applies
/// the system Liquid Glass grouping around it, so this view just supplies
/// the label + tinted symbol. Its SF Symbol animation is state-driven —
/// the symbol morphs when the bridge changes phase, pulses while it
/// negotiates, and gives one bounce when it comes up — never decorative.
struct ClipboardStatusPill: View {
    let snapshot: SpiceStatusSnapshot

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.pulse, isActive: snapshot.state == .connecting)
            .symbolEffect(.bounce, value: snapshot.state == .connected)
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
        case .notStarted:  String.SFSymbols.clipboard
        case .connecting:  String.SFSymbols.clipboardFill
        case .connected:   String.SFSymbols.clipboardFill
        case .failed:      String.SFSymbols.exclamationmarkTriangleFill
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
