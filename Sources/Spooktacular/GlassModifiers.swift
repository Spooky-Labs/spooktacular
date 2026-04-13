import SwiftUI

/// Applies `.buttonStyle(.glass)` on macOS 26+ (Liquid Glass),
/// falls back to `.borderedProminent` on older versions.
///
/// The `.glass` button style only exists in the macOS 26 SDK
/// (Swift 6.1+). On older SDKs the symbol is undefined, so
/// we gate it with `#if compiler(>=6.1)` at compile time,
/// then use `#available` for the runtime check.
struct GlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.1)
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
