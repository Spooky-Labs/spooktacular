import SwiftUI

// MARK: - Glass Button Modifier

/// Applies `.buttonStyle(.glass)` — the macOS 26 Liquid Glass
/// button style introduced with the Tahoe SDK.
///
/// The Liquid Glass design language is documented at
/// <https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass>
/// and the `.glass` / `.glassProminent` button styles at
/// <https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass>.
///
/// Prior revisions of this file carried `#if compiler(>=6.2)` +
/// `if #available(macOS 26, *)` fallbacks to `.borderedProminent`
/// / `.ultraThinMaterial`. Those gates became dead code when the
/// minimum deployment target moved to macOS 26 — the project
/// only builds against Swift 6.2+ on a macOS 26 SDK, so the
/// Liquid Glass symbols are always present and the runtime
/// availability check is always true. Keeping them in would
/// just obscure the happy path.
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.glass)
    }
}

// MARK: - Glass Card Modifier

/// Applies a Liquid Glass effect background for elevated
/// content cards — hardware summaries, status panels, inspector
/// sections. Uses the `.regular.interactive()` variant so the
/// card picks up the subtle pressure / hover response Apple
/// ships with interactable glass surfaces.
///
/// Apply sparingly: the macOS HIG calls out glass as a hierarchy
/// signal, not a default treatment.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}

// MARK: - Glass Status Badge Modifier

/// Applies a glass capsule for small status badges (running
/// indicator, port count, etc.).
struct GlassStatusBadgeModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: .capsule)
    }
}

// MARK: - Glass Section Header Modifier

/// Applies Liquid Glass styling to section headers in sheets
/// and inspectors.
struct GlassSectionHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }
}

// MARK: - View Extensions

extension View {
    /// Hides the toolbar's default material so Liquid Glass
    /// toolbar elements share a single container. Safe to call
    /// unconditionally — on macOS 26 the standard
    /// `NavigationSplitView` toolbar auto-adopts Liquid Glass;
    /// this helper just removes the duplicated background.
    @ViewBuilder
    func toolbarApplyingGlassContainer() -> some View {
        self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .containerBackground(.clear, for: .window)
    }

    /// Applies the Liquid Glass button style.
    func glassButton() -> some View {
        modifier(GlassButtonModifier())
    }

    /// Applies a Liquid Glass card background.
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius))
    }

    /// Applies a Liquid Glass capsule badge.
    func glassStatusBadge() -> some View {
        modifier(GlassStatusBadgeModifier())
    }

    /// Applies a Liquid Glass section header.
    func glassSectionHeader() -> some View {
        modifier(GlassSectionHeaderModifier())
    }
}
