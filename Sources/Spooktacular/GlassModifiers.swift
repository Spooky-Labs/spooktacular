import SwiftUI

/// Applies `.buttonStyle(.glass)` on macOS 26+ (Liquid Glass),
/// falls back to `.borderedProminent` on older versions.
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

/// Applies `.glassEffect()` on macOS 26+, no-op on older.
struct GlassEffectModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect()
        } else {
            content
        }
    }
}

extension View {
    /// Applies Liquid Glass effect on macOS 26+.
    func glassIfAvailable() -> some View {
        modifier(GlassEffectModifier())
    }
}
