import SwiftUI
import AppKit
import SpiceClipboardAgent

/// Spooktacular Guest Tools — the in-guest companion app.
///
/// A sandboxed menu-bar `.app` that ships inside every
/// Spooktacular macOS VM under `/Applications/Spooktacular
/// Guest Tools.app`. Auto-installed pre-first-boot by
/// `DiskInjector` + `AppBundleBootstrapTemplate` (see
/// `Sources/SpooktacularApplication/`), so the user never
/// drags a DMG.
///
/// Responsibilities:
///
/// - SPICE clipboard bridge via the `SpiceClipboardAgent`
///   library, with menu-bar status and launch-at-login
///   registration via `SMAppService.mainApp`.
/// - HTTP/vsock guest-agent API (`SpooktacularGuestAgentCore`),
///   which absorbed the surface area of the retired
///   `spooktacular-agent` executable.
/// - `/api/v1/spice/status` endpoint so the host can drive a
///   tri-state clipboard indicator in the workspace toolbar.
///
/// `LSUIElement=true` in `Info.plist` so there's no Dock tile
/// or main window — the entire UI is the menu-bar extra.
@main
struct SpooktacularGuestToolsApp: App {
    @State private var controller = AgentController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            // HStack of icon + explicit "SGT" text prefix
            // guarantees SOMETHING visible even if the SF
            // Symbol fails to render (seen rarely on macOS 15
            // beta builds where new Symbol packs haven't
            // propagated). The text is narrow enough to sit
            // comfortably next to the clock without crowding
            // other menu-bar extras.
            Label {
                Text("SGT")
            } icon: {
                Image(systemName: controller.status.menuBarSymbol)
            }
            .foregroundStyle(controller.status.menuBarTint)
        }
        .menuBarExtraStyle(.menu)
    }
}
