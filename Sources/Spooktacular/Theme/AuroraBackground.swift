import SwiftUI

/// The séance-room ambience — a slow aurora of wisp and vital
/// light drifting through the night grounds.
///
/// A single 3×3 `MeshGradient` carries the whole effect: the outer
/// ring holds the adaptive Apparition grounds, while two interior
/// vertices are tinted with very-low-alpha ``Apparition/wisp``
/// (~6%) and ``Apparition/vital`` (~4%) washes. In the light
/// ("Fog") appearance the same mesh resolves to fog grounds and the
/// tints drop even lower, so the ambience reads as a whisper in
/// both schemes. The tint never replaces the system window
/// background — callers layer this behind materials as a bias.
///
/// ## Performance
/// This is deliberately the app's *only* ambient effect, and it is
/// cheap by construction: one mesh, no blurs, no layered shaders,
/// driven by a `TimelineView(.animation(minimumInterval: 1/12))` so
/// the drift redraws at most 12 fps instead of the display's full
/// refresh rate. The two moving vertices follow multi-second
/// sin/cos orbits, so consecutive frames differ by fractions of a
/// point — 12 fps is visually indistinguishable from 120 fps here.
///
/// ## Accessibility
/// When Reduce Motion is on the `TimelineView` is skipped entirely
/// and the static mesh renders once — same ambience, zero motion.
///
/// Docs:
/// - <https://developer.apple.com/documentation/SwiftUI/MeshGradient/init(width:height:points:colors:background:smoothsColors:colorSpace:)>
/// - <https://developer.apple.com/documentation/SwiftUI/TimelineSchedule/animation(minimumInterval:paused:)>
struct AuroraBackground: View {

    /// Overall strength of the ambience. Defaults to full; callers
    /// hosting dense content (tables, logs) may lower it so the
    /// aurora stays behind the information, not in front of it.
    var opacity: Double = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// `true` while any AppKit menu is tracking — the main menu bar
    /// (File, Edit, …), a right-click context menu, or the
    /// ``MenuBarExtra`` dropdown.
    ///
    /// While a menu tracks, AppKit runs a *modal* event loop
    /// (`NSEventTrackingRunLoopMode`). A window-level
    /// `TimelineView(.animation)` that commits a redraw every frame
    /// invalidates the window during that loop, which AppKit treats
    /// as an interrupting event and ends menu tracking — so an open
    /// menu dismisses the instant it appears. Pausing the ~12 fps
    /// drift for the fraction of a second a menu is open is visually
    /// imperceptible (the orbits move fractions of a point per
    /// frame) and lets menus stay open. Driven by
    /// `NSMenu.didBeginTracking` / `didEndTracking`.
    @State private var menuIsTracking = false

    var body: some View {
        Group {
            if reduceMotion {
                // Static séance room: the same mesh, frozen at its
                // rest pose. No TimelineView is created at all, so
                // there is no per-frame work to suppress.
                mesh(at: 0)
            } else {
                // `paused:` freezes the schedule while a menu tracks;
                // see ``menuIsTracking``.
                TimelineView(
                    .animation(minimumInterval: 1.0 / 12.0, paused: menuIsTracking)
                ) { context in
                    mesh(at: context.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            menuIsTracking = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuIsTracking = false
        }
    }

    // MARK: - Mesh

    /// The 3×3 mesh at a given instant. Corner and edge vertices
    /// are pinned so the mesh hull always covers the view; the two
    /// tinted vertices (center wisp, lower-middle vital) drift on
    /// small, slow sin/cos orbits. Any hairline the drifting
    /// lower vertex opens along the bottom edge is filled by the
    /// `background:` ground, so it stays invisible.
    private func mesh(at time: TimeInterval) -> some View {
        // Multi-second, mutually prime periods so the two orbits
        // never visibly sync up.
        let wispAngle = time * (2 * .pi / 17)
        let vitalAngle = time * (2 * .pi / 23)

        let wispPoint = SIMD2<Float>(
            0.42 + 0.06 * Float(sin(wispAngle)),
            0.44 + 0.05 * Float(cos(wispAngle))
        )
        let vitalPoint = SIMD2<Float>(
            0.62 + 0.07 * Float(cos(vitalAngle)),
            0.96 + 0.03 * Float(sin(vitalAngle))
        )

        // In the light ("Fog") appearance the washes drop even
        // lower — fog wants a hint, not a glow.
        let wispAmount = colorScheme == .dark ? 0.06 : 0.035
        let vitalAmount = colorScheme == .dark ? 0.04 : 0.025

        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), wispPoint, .init(1, 0.5),
                .init(0, 1), vitalPoint, .init(1, 1),
            ],
            colors: [
                Apparition.night0, Apparition.night1, Apparition.night0,
                Apparition.night1,
                Apparition.night2.mix(with: Apparition.wisp, by: wispAmount),
                Apparition.night1,
                Apparition.night2, Apparition.night1.mix(with: Apparition.vital, by: vitalAmount),
                Apparition.night0,
            ],
            background: Apparition.night0
        )
    }
}
