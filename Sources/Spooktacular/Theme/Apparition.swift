import AppKit
import SwiftUI

/// The Apparition design language — Spooktacular's visual identity.
///
/// Spooktacular's VMs are *apparitions*: they materialize, work, and
/// dissipate. This namespace is the single source of truth for the
/// "Night & Wisp" palette and the app's shared motion voice.
///
/// ## Palette contract
/// - ``wisp`` is the ONE accent. It marks the primary action and
///   brand moments — nothing else. Never use it to mean "running".
/// - ``vital`` and ``lantern`` are *semantic* lifecycle colors
///   (alive / in-progress), deliberately separate from the accent.
/// - ``night0``, ``night1``, ``night2`` and ``fogText`` are ambient
///   ground/text tints layered **over** system materials. They bias
///   the system window background; they never replace it.
///
/// Every color adapts to light ("Fog") and dark ("Night") appearance
/// via AppKit's dynamic-provider catalog colors, resolved lazily per
/// draw using the current appearance:
/// <https://developer.apple.com/documentation/AppKit/NSColor/init(name:dynamicProvider:)>
enum Apparition {

    // MARK: - Accent

    /// Wisp violet — the app's single accent color.
    ///
    /// Will-o'-the-wisp — the séance's cool glow: spectral, moonlit,
    /// deliberately distinct from ``vital``'s teal. Reserved for the
    /// primary action on a surface and for brand moments (the one
    /// `glassProminent` button). Dark: `#7C5CFF`, a deep royal
    /// violet that still glows on night grounds; light ("Fog"):
    /// `#4A38C8`, deepened so it holds AA contrast on fog grounds.
    static let wisp = dynamic(
        name: "wisp",
        dark: rgb(0x7C5CFF),
        light: rgb(0x4A38C8)
    )

    /// Deep wisp — the accent's low register.
    ///
    /// A darker sibling of ``wisp`` for gradient stops, pressed
    /// states, and moments where full wisp would shout. Dark:
    /// `#5E42E0`; light: `#35279B`.
    static let wispDeep = dynamic(
        name: "wispDeep",
        dark: rgb(0x5E42E0),
        light: rgb(0x35279B)
    )

    // MARK: - Semantic lifecycle colors

    /// Vital teal — alive / online / success.
    ///
    /// The color of a running apparition's heartbeat: status dots,
    /// "running" badges, healthy vitals. Dark: `#5FE8C8`; light:
    /// `#0FA98A`.
    static let vital = dynamic(
        name: "vital",
        dark: rgb(0x5FE8C8),
        light: rgb(0x0FA98A)
    )

    /// Lantern gold — booting / in-progress.
    ///
    /// The color of a materializing apparition: install progress,
    /// boot states, pending work. Dark: `#FFD166`; light: `#A87B0B`.
    static let lantern = dynamic(
        name: "lantern",
        dark: rgb(0xFFD166),
        light: rgb(0xA87B0B)
    )

    // MARK: - Grounds

    /// The deepest ground tint — the séance room's darkest corner.
    ///
    /// Dark ("Night"): `#08090F`; light ("Fog"): `#ECEAF1`. Use as
    /// an ambient wash behind system materials, never as an opaque
    /// replacement for the window background.
    static let night0 = dynamic(
        name: "night0",
        dark: rgb(0x08090F),
        light: rgb(0xECEAF1)
    )

    /// The middle ground tint. Dark: `#0E1018`; light: `#F6F5FA`.
    static let night1 = dynamic(
        name: "night1",
        dark: rgb(0x0E1018),
        light: rgb(0xF6F5FA)
    )

    /// The raised ground tint — cards and elevated surfaces lean on
    /// this. Dark: `#171A26`; light: `#FFFFFF`.
    static let night2 = dynamic(
        name: "night2",
        dark: rgb(0x171A26),
        light: rgb(0xFFFFFF)
    )

    // MARK: - Text

    /// Fog text — the primary text tint.
    ///
    /// A cool off-white in the dark ("Night") appearance (`#E8E6F2`)
    /// and a deep ink in the light ("Fog") appearance (`#2A2833`).
    /// Prefer system semantic text styles for body copy; reach for
    /// this when a brand surface needs the Apparition voice.
    static let fogText = dynamic(
        name: "fogText",
        dark: rgb(0xE8E6F2),
        light: rgb(0x2A2833)
    )

    // MARK: - Motion voice

    /// The app's signature spring — every state-bound animation
    /// shares this so all surfaces move with one voice.
    ///
    /// A ~0.35 s perceptual duration with a gentle bounce, built on
    /// SwiftUI's spring model:
    /// <https://developer.apple.com/documentation/SwiftUI/Animation/spring(duration:bounce:blendDuration:)>
    static let spring = Animation.spring(duration: 0.35, bounce: 0.18)

    /// The quick response curve for small, immediate feedback
    /// (hover states, badge swaps) — a ~0.2 s smooth spring with no
    /// bounce:
    /// <https://developer.apple.com/documentation/SwiftUI/Animation/smooth(duration:extraBounce:)>
    static let quick = Animation.smooth(duration: 0.2)

    // MARK: - Private helpers

    /// Builds an adaptive SwiftUI `Color` from explicit dark/light
    /// AppKit colors.
    ///
    /// Uses `NSColor(name:dynamicProvider:)` — AppKit calls the
    /// provider with the current drawing appearance each time the
    /// color's components are needed, so the value tracks
    /// appearance changes automatically. The provider switches on
    /// `bestMatch(from:)` against `.aqua` / `.darkAqua`, which also
    /// resolves the high-contrast variants to their base
    /// appearance.
    ///
    /// Docs:
    /// - <https://developer.apple.com/documentation/AppKit/NSColor/init(name:dynamicProvider:)>
    /// - <https://developer.apple.com/documentation/AppKit/NSAppearance/bestMatch(from:)>
    private static func dynamic(
        name: String,
        dark: NSColor,
        light: NSColor
    ) -> Color {
        Color(
            nsColor: NSColor(
                // Per the docs the color name "should be
                // universally unique" — namespace it.
                name: "com.spookylabs.spooktacular.apparition.\(name)"
            ) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? dark
                    : light
            }
        )
    }

    /// Builds an sRGB `NSColor` from a 24-bit `0xRRGGBB` literal —
    /// keeps the palette declarations readable and diffable.
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
