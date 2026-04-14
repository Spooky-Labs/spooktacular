import SwiftUI

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
}
