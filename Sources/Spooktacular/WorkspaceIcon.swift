import AppKit
import SwiftUI
import SpooktacularCore
import SpooktacularInfrastructureApple

/// Swaps the process's Dock tile to reflect the frontmost workspace.
///
/// macOS gives a single app exactly one Dock entry — achieving
/// "one Dock icon per VM" the way GhostVM does requires helper
/// apps, which is out of scope. Instead, we do the next-best
/// reference-quality thing: when a workspace window becomes key,
/// swap `NSApp.applicationIconImage` to that workspace's custom
/// icon. When the library window becomes key (or no workspace is
/// focused), restore the app's default icon.
///
/// Callers subscribe by calling ``focusChanged(to:)`` from a
/// `NSWindowDelegate` or SwiftUI `.onReceive` observer. The actor
/// isolation lives on `@MainActor` because both AppKit and the
/// icon renderer require it.
@MainActor
final class WorkspaceIconCoordinator {

    /// The original icon Spooktacular ships with, restored when
    /// no workspace is in the foreground.
    private let defaultIcon: NSImage?

    /// Cached custom icons so we don't re-render each focus change.
    private var cache: [IconSpec: NSImage] = [:]

    /// The icon currently installed on the Dock tile. Used to skip
    /// redundant re-installs — swapping the icon image is not free.
    private var installedSpec: IconSpec?

    init() {
        self.defaultIcon = NSApplication.shared.applicationIconImage
    }

    /// Updates the Dock tile to reflect the given workspace icon.
    ///
    /// Pass `nil` to restore the app's default icon (e.g. when the
    /// library window is key or all workspaces close).
    func focusChanged(to spec: IconSpec?) {
        guard installedSpec != spec else { return }
        installedSpec = spec

        if let spec {
            let image = cache[spec] ?? WorkspaceIconRenderer.render(spec, size: 512)
            cache[spec] = image
            NSApplication.shared.applicationIconImage = image
        } else {
            NSApplication.shared.applicationIconImage = defaultIcon
        }
    }
}
