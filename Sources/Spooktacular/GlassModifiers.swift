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
        // The prominent button IS the wisp moment ("Night & Wisp"
        // contract: one accent, spent on the single primary action
        // per surface). Carrying the tint here — instead of a
        // root-level `.tint` on the window — keeps every other
        // glass button neutral by default; a root tint cascades
        // into every glass fill and turns secondary buttons into
        // candy.
        content
            .buttonStyle(.glassProminent)
            .tint(Apparition.wisp)
    }
}

// MARK: - Hover Symbol Bounce

/// One-shot symbol bounce when the pointer enters the control —
/// the hover half of the "extremely responsive" contract.
///
/// The bounce is the discrete `.symbolEffect(_:value:)` variant
/// keyed off a hover counter, so it fires exactly once per pointer
/// entry (never loops) and is skipped entirely under Reduce
/// Motion. Apply to a `Label`/`Image` inside a button, not the
/// button itself, so only the symbol animates.
struct HoverSymbolBounce: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverCount = 0

    func body(content: Content) -> some View {
        content
            .symbolEffect(.bounce, value: hoverCount)
            .onHover { hovering in
                guard hovering, !reduceMotion else { return }
                hoverCount += 1
            }
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

    /// Bounces the symbol once when the pointer enters — apply to
    /// the `Label` inside interactive controls. No-op under Reduce
    /// Motion; never loops.
    func hoverSymbolBounce() -> some View {
        modifier(HoverSymbolBounce())
    }
}
