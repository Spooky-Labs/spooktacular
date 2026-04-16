import Foundation
import AppKit
import SwiftUI
import SpookCore

/// Renders ``IconSpec`` values into `NSImage` for use in the Dock
/// tile, library cards, and app-switcher entries.
///
/// The renderer is the only place in the project that bridges the
/// domain-layer ``IconSpec`` to AppKit/SwiftUI — views upstream
/// receive a ready-to-use `NSImage` and don't have to know which
/// mode the spec uses.
///
/// ## Caching
///
/// Icons are rendered on demand. Callers that show many icons
/// (library grid) should cache the result themselves keyed by
/// ``IconSpec``'s `Hashable` conformance.
public enum WorkspaceIconRenderer {

    // MARK: - Public API

    /// Renders an icon for the given spec at the requested pixel size.
    ///
    /// - Parameters:
    ///   - spec: The declarative icon description.
    ///   - size: The edge length in points. The returned image is
    ///     square with a matching `NSImage.size`. Multi-scale
    ///     representations are not produced — callers that need
    ///     `@2x` can re-render at the doubled size.
    /// - Returns: A fully composed `NSImage`. Falls back to
    ///   ``IconSpec/defaultSpec`` if the requested spec cannot be
    ///   resolved (missing app, missing preset, missing symbol).
    @MainActor
    public static func render(_ spec: IconSpec, size: CGFloat = 128) -> NSImage {
        switch spec {
        case .cloneApp(let bundleID):
            return renderCloneApp(bundleID: bundleID, size: size)
                ?? render(IconSpec.defaultSpec, size: size)
        case .stack(let top, let bottom):
            return renderStack(top: top, bottom: bottom, size: size)
                ?? render(IconSpec.defaultSpec, size: size)
        case .glassFrame(let symbol, let tint):
            return renderGlassFrame(symbol: symbol, tint: tint, size: size)
                ?? fallbackSymbol(size: size)
        case .preset(let name):
            return renderPreset(named: name, size: size)
                ?? render(IconSpec.defaultSpec, size: size)
        }
    }

    // MARK: - Mode: cloneApp

    @MainActor
    private static func renderCloneApp(bundleID: String, size: CGFloat) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        image.size = NSSize(width: size, height: size)
        return image
    }

    // MARK: - Mode: stack

    @MainActor
    private static func renderStack(top: String, bottom: String, size: CGFloat) -> NSImage? {
        let pixel = NSSize(width: size, height: size)
        let image = NSImage(size: pixel)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Bottom symbol fills the frame.
        if let bottomImage = symbolImage(bottom, pointSize: size * 0.85, weight: .regular) {
            let rect = centered(in: pixel, size: bottomImage.size)
            bottomImage.draw(in: rect)
        }

        // Top symbol sits in the lower-right, overlapping the bottom.
        if let topImage = symbolImage(top, pointSize: size * 0.55, weight: .bold) {
            let badgeSize = topImage.size
            let origin = NSPoint(
                x: pixel.width - badgeSize.width - 4,
                y: 4
            )
            topImage.draw(
                in: NSRect(origin: origin, size: badgeSize),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
        }
        return image
    }

    // MARK: - Mode: glassFrame

    @MainActor
    private static func renderGlassFrame(symbol: String, tint: IconSpec.Tint, size: CGFloat) -> NSImage? {
        let pixel = NSSize(width: size, height: size)
        let cornerRadius = size * 0.225   // macOS Squircle-ish
        let image = NSImage(size: pixel)
        image.lockFocus()
        defer { image.unlockFocus() }

        // Rounded-rect glass background — gradient from tint to lighter.
        let path = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: pixel),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        let tintColor = nsColor(for: tint)
        let gradient = NSGradient(colors: [
            tintColor.blended(withFraction: 0.35, of: .white) ?? tintColor,
            tintColor,
        ])
        gradient?.draw(in: path, angle: -75)

        // Soft inner highlight for the Liquid Glass feel.
        let highlightPath = NSBezierPath(
            roundedRect: NSRect(
                x: size * 0.08,
                y: size * 0.55,
                width: size * 0.84,
                height: size * 0.38
            ),
            xRadius: cornerRadius * 0.8,
            yRadius: cornerRadius * 0.8
        )
        NSColor.white.withAlphaComponent(0.14).setFill()
        highlightPath.fill()

        // Centered symbol in white.
        if let glyph = symbolImage(symbol, pointSize: size * 0.52, weight: .semibold, color: .white) {
            let rect = centered(in: pixel, size: glyph.size)
            glyph.draw(in: rect)
        }
        return image
    }

    // MARK: - Mode: preset

    @MainActor
    private static func renderPreset(named name: String, size: CGFloat) -> NSImage? {
        // Presets are bundled PNG image sets. The app target exposes
        // them via Bundle.main; if the image isn't found there the
        // caller falls back to defaultSpec.
        guard let image = Bundle.main.image(forResource: "preset-\(name)") else {
            return nil
        }
        image.size = NSSize(width: size, height: size)
        return image
    }

    // MARK: - Helpers

    @MainActor
    private static func symbolImage(
        _ symbolName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor = .labelColor
    ) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let raw = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
            return nil
        }
        guard let configured = raw.withSymbolConfiguration(config) else {
            return nil
        }
        return tintedImage(configured, color: color)
    }

    /// Returns a new image with every opaque pixel replaced by `color`,
    /// preserving the alpha channel. Used so SF Symbols can be drawn
    /// in a specific color without going through `NSImageView`.
    @MainActor
    private static func tintedImage(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        defer { tinted.unlockFocus() }

        image.draw(in: NSRect(origin: .zero, size: size))

        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        return tinted
    }

    @MainActor
    private static func fallbackSymbol(size: CGFloat) -> NSImage {
        let image = NSImage(
            systemSymbolName: "questionmark.diamond.fill",
            accessibilityDescription: "unknown"
        ) ?? NSImage()
        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func centered(in canvas: NSSize, size: NSSize) -> NSRect {
        NSRect(
            x: (canvas.width - size.width) / 2,
            y: (canvas.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    @MainActor
    private static func nsColor(for tint: IconSpec.Tint) -> NSColor {
        switch tint {
        case .accent: return NSColor.controlAccentColor
        case .blue:   return NSColor.systemBlue
        case .purple: return NSColor.systemPurple
        case .pink:   return NSColor.systemPink
        case .red:    return NSColor.systemRed
        case .orange: return NSColor.systemOrange
        case .yellow: return NSColor.systemYellow
        case .green:  return NSColor.systemGreen
        case .teal:   return NSColor.systemTeal
        case .mono:   return NSColor.labelColor
        }
    }
}
