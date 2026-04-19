import SwiftUI

// Liquid Glass (macOS 26) is an opt-in material that renders a
// refractive, dynamic surface over underlying content. On older
// macOS releases we fall back to `ultraThinMaterial` — which
// renders as a translucent vibrancy blur and is the closest legacy
// equivalent. Every modifier in this file uses
// `#if compiler(>=6.2)` + `#available(macOS 26.0, *)` so a single
// binary targets macOS 14–26+ without runtime crashes.
//
// Docs:
// - Adopting Liquid Glass:
//   https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass
// - `glassEffect(_:in:)`:
//   https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)
// - `GlassEffectContainer`:
//   https://developer.apple.com/documentation/swiftui/glasseffectcontainer
// - `buttonStyle(.glass)`:
//   https://developer.apple.com/documentation/swiftui/buttonstyle-swift.type/glass
// - `containerBackground(_:for:)`:
//   https://developer.apple.com/documentation/swiftui/view/containerbackground(_:for:)

// MARK: - Glass Button Modifier

/// Applies `.buttonStyle(.glass)` on macOS 26+ (Liquid Glass),
/// falls back to `.borderedProminent` on older versions.
///
/// The `.glass` button style only exists in the macOS 26 SDK
/// (Swift 6.2+ / Xcode 26). On older SDKs the symbol is undefined, so
/// we gate it with `#if compiler(>=6.2)` at compile time,
/// then use `#available` for the runtime check.
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderedProminent)
        }
        #else
        content.buttonStyle(.borderedProminent)
        #endif
    }
}

// MARK: - Glass Card Modifier

/// Applies a glass effect background on macOS 26+, falls back
/// to `.ultraThinMaterial` on older versions.
///
/// Use for elevated content cards — hardware summaries, status
/// panels, and inspector sections. Avoids overuse: only apply
/// to containers that create visual hierarchy.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
        #else
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        #endif
    }
}

// MARK: - Glass Status Badge Modifier

/// Applies a subtle glass capsule effect on macOS 26+ for status
/// badges and small indicators. Falls back to a tinted background.
struct GlassStatusBadgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .glassEffect(.regular, in: .capsule)
        } else {
            content
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        #else
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
        #endif
    }
}

// MARK: - Glass Section Header Modifier

/// Applies a glass effect to section headers on macOS 26+.
/// Falls back to a simple background treatment.
struct GlassSectionHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .rect(cornerRadius: 8))
        } else {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
        #else
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        #endif
    }
}

// MARK: - Window Background

/// Applies a window-wide Liquid Glass / material background,
/// picking the best Apple API for the running OS.
///
/// - **macOS 15+**: `containerBackground(.ultraThinMaterial,
///   for: .window)` — purpose-built for window-level material
///   fills, resilient to split-view and inspector reshuffling.
///   Docs: https://developer.apple.com/documentation/swiftui/view/containerbackground(_:for:)
/// - **macOS 14**: `background(.ultraThinMaterial)` — the
///   documented fallback for general material fills.
///   Docs: https://developer.apple.com/documentation/swiftui/material
///
/// On macOS 26 the underlying material renders as Liquid Glass
/// automatically — no extra API call needed, the system
/// re-materializes the existing container background.
struct WindowGlassBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.containerBackground(.ultraThinMaterial, for: .window)
        } else {
            content.background(.ultraThinMaterial)
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Wraps the toolbar region in a `GlassEffectContainer` on
    /// macOS 26+ so related toolbar glass elements share a
    /// single material layer. No-op on earlier versions.
    ///
    /// Docs: https://developer.apple.com/documentation/swiftui/view/toolbarbackgroundvisibility(_:for:)
    @ViewBuilder
    func toolbarApplyingGlassContainer() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .containerBackground(.clear, for: .window)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Applies the Liquid Glass button style on macOS 26+,
    /// `.borderedProminent` on earlier versions.
    func glassButton() -> some View {
        modifier(GlassButtonModifier())
    }

    /// Applies a glass card background on macOS 26+,
    /// `.ultraThinMaterial` on earlier versions.
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Applies a glass capsule badge on macOS 26+,
    /// a tinted capsule on earlier versions.
    func glassStatusBadge() -> some View {
        modifier(GlassStatusBadgeModifier())
    }

    /// Applies a glass section header on macOS 26+,
    /// a subtle background on earlier versions.
    func glassSectionHeader() -> some View {
        modifier(GlassSectionHeaderModifier())
    }

    /// Applies the Liquid Glass window background — use at the
    /// root of a `WindowGroup` scene to give the window a
    /// material chrome that blends with Apple's window chrome on
    /// macOS 26, and a vibrancy-blur on older releases.
    ///
    /// Prefer this over hand-rolling the `#available` selector at
    /// every scene root. The library window wires it in
    /// ``SpooktacularApp`` via a private `libraryWindowBackground`
    /// extension; this public form is for new scene roots (help
    /// window, workspace, sheets).
    func windowGlassBackground() -> some View {
        modifier(WindowGlassBackgroundModifier())
    }

    /// Groups a block of related views into a single shared glass
    /// material layer on macOS 26+. Use this around toolbar
    /// button groups that belong together (Stop / Snapshots /
    /// Ports), or around a row of inline chips, so they render
    /// as one continuous glass shape rather than N separate
    /// blurs. No-op on macOS 14/15 — the material fallback
    /// already composes correctly without the container.
    ///
    /// Docs:
    /// https://developer.apple.com/documentation/swiftui/glasseffectcontainer
    @ViewBuilder
    func glassEffectGroup<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content() }
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

// MARK: - Free-standing helpers

/// Groups a block of related views into a single shared glass
/// material layer on macOS 26+. See `View.glassEffectGroup` for
/// the in-view form; this free-standing helper lets call sites
/// that don't have a `self` (e.g. inside `@ToolbarContentBuilder`
/// the toolbar leaves the container out) still reach the same
/// layering primitive when needed.
///
/// Docs:
/// https://developer.apple.com/documentation/swiftui/glasseffectcontainer
@ViewBuilder
@MainActor
func GlassGroup<Content: View>(
    @ViewBuilder content: @MainActor () -> Content
) -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
        GlassEffectContainer { content() }
    } else {
        content()
    }
    #else
    content()
    #endif
}
