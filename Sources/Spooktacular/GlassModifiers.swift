import SwiftUI

// MARK: - Glass Button Modifiers

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

/// Applies `.buttonStyle(.glassProminent)` — the Liquid Glass
/// equivalent of `.borderedProminent`. Use for the single
/// primary action on a surface (the "Open Workspace" button on
/// the VM detail view, "Create Workspace" on empty state).
///
/// Per Apple's [HIG / Liquid Glass guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass),
/// prominent glass draws the user's eye exactly once per view;
/// surrounding secondary actions should stay on `.glass` or an
/// even lighter style so the hierarchy reads cleanly.
struct GlassProminentButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.glassProminent)
    }
}

// MARK: - Material Section Header Modifier

/// Backs a section header in sheets and inspectors with a
/// standard material chip.
///
/// Section headers live in the content layer, and Apple's HIG is
/// explicit — ["Don't use Liquid Glass in the content
/// layer."](https://developer.apple.com/design/human-interface-guidelines/materials)
/// A `.regularMaterial` fill gives the header its recessed
/// affordance without borrowing the floating-chrome material
/// that Liquid Glass reserves for controls and navigation.
struct MaterialSectionHeaderModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
    }
}

// MARK: - View Extensions

extension View {
    /// Applies the Liquid Glass button style.
    func glassButton() -> some View {
        modifier(GlassButtonModifier())
    }

    /// Applies the prominent Liquid Glass button style. Use for
    /// the single primary action on a surface — the "Open
    /// Workspace" button on `VMDetailView`, "Create Workspace"
    /// on the empty state, etc.
    func glassProminentButton() -> some View {
        modifier(GlassProminentButtonModifier())
    }

    /// Backs a section header with a standard material chip. Kept
    /// out of the Liquid Glass family on purpose — headers are
    /// content, and the HIG reserves Liquid Glass for chrome.
    func materialSectionHeader() -> some View {
        modifier(MaterialSectionHeaderModifier())
    }
}
