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
