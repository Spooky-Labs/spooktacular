import SwiftUI

// MARK: - Glass Button Modifier

/// Applies `.buttonStyle(.glass)` on macOS 26+ (Liquid Glass),
/// falls back to `.bordered` on older versions.
///
/// Use for **secondary** actions — the translucent variant that
/// shows the content behind it. Pair with
/// ``glassProminentButton()`` for the primary-action counterpart.
///
/// Apple guidance: "Controls like sliders and toggles fluidly
/// morph into menus and popovers" — you don't need to override
/// shapes; the system supplies the right shape per platform when
/// you use `.buttonStyle(.glass)` with the default border shape.
///
/// Docs:
/// - https://developer.apple.com/documentation/swiftui/buttonstyle-swift.type/glass
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
        #else
        content.buttonStyle(.bordered)
        #endif
    }
}

// MARK: - Glass Prominent Button Modifier

/// Applies `.buttonStyle(.glassProminent)` on macOS 26+,
/// `.borderedProminent` on older versions.
///
/// Use for the **primary** action in a given context — Create,
/// Save, Open Workspace, Start. Opaque variant that doesn't
/// show content through — makes the CTA stand out from the
/// secondary glass controls around it. Per Apple's guidance,
/// use sparingly: one prominent button per logical action area.
///
/// Docs:
/// - https://developer.apple.com/documentation/swiftui/buttonstyle-swift.type/glassprominent
struct GlassProminentButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
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

// MARK: - View Extensions

extension View {
    /// Wraps the toolbar region in a `GlassEffectContainer` on
    /// macOS 26+ so related toolbar glass elements share a
    /// single material layer. No-op on earlier versions.
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
    /// `.bordered` on earlier versions. Use for **secondary**
    /// actions; pair with ``glassProminentButton()`` for primaries.
    func glassButton() -> some View {
        modifier(GlassButtonModifier())
    }

    /// Applies the prominent Liquid Glass button style on
    /// macOS 26+, `.borderedProminent` on earlier versions. Use
    /// for the **primary** action in a given context — exactly
    /// one per logical action area (per HIG).
    ///
    /// Docs: https://developer.apple.com/documentation/swiftui/buttonstyle-swift.type/glassprominent
    func glassProminentButton() -> some View {
        modifier(GlassProminentButtonModifier())
    }

    /// Groups a block of related views into a single shared
    /// glass material layer on macOS 26+ via `GlassEffectContainer`.
    /// Per Apple's Liquid Glass adoption guide: "Always use
    /// GlassEffectContainer for multiple elements" — it optimizes
    /// rendering by sharing the sampling region and enables
    /// morphing transitions between neighboring glass elements.
    /// No-op on earlier macOS versions.
    ///
    /// Docs: https://developer.apple.com/documentation/swiftui/glasseffectcontainer
    @ViewBuilder
    func glassContainer() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// Applies `.backgroundExtensionEffect()` on macOS 26+ so
    /// the content beneath a neighboring sidebar or inspector
    /// "peeks through" — the sidebar/inspector's Liquid Glass
    /// samples a mirrored, blurred copy of the content edge.
    /// No-op on earlier macOS.
    ///
    /// From Apple's Liquid Glass adoption guide: "A background
    /// extension effect creates a sense of extending a
    /// background under a sidebar or inspector, without actually
    /// scrolling or placing content under it." Apply to the
    /// detail / main content region of a `NavigationSplitView`
    /// so the inspector's glass is legible and feels connected
    /// to the content.
    ///
    /// Docs: https://developer.apple.com/documentation/swiftui/view/backgroundextensioneffect()
    @ViewBuilder
    func backgroundExtendedUnderSidebarsAndInspectors() -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            self.backgroundExtensionEffect()
        } else {
            self
        }
        #else
        self
        #endif
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
}
