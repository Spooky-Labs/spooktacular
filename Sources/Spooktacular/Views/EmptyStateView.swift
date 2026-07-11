import SwiftUI

/// Library empty state — replaces the default `ContentUnavailable`
/// look with a tinted hero symbol and a gentle one-shot drift.
///
/// Shown when the user has zero VMs, layered directly over the
/// ``AuroraBackground`` in the library's detail column — content
/// over ambience, no material in between. Meant to be inviting and
/// self-explanatory so first-run doesn't feel like a dead end.
///
/// The entrance drift is a one-shot `phaseAnimator` bound to the
/// view's appearance and is fully gated on Reduce Motion: when the
/// setting is on, the trigger never fires, so the animator never
/// leaves its rest phase and the hero renders static.
struct EmptyStateView: View {

    let onCreate: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var phase: AnimationPhase = .drift

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 72, weight: .light))
                // `ShapeStyle.tint` reflects the app's accent
                // color (or an explicit `.tint(_:)` if a view
                // higher up sets one) — per Apple's Liquid Glass
                // "color sparingly" guidance, a single semantic
                // tint reads cleaner here than a bespoke two-stop
                // purple/blue gradient.
                .foregroundStyle(.tint)
                .phaseAnimator([AnimationPhase.drift, .lift, .settle], trigger: phase) { content, phase in
                    content
                        .offset(y: phase == .lift ? -6 : 0)
                } animation: { _ in
                    .easeInOut(duration: 2.4)
                }
                .padding(.bottom, 8)

            VStack(spacing: 8) {
                Text("No workspaces yet.")
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                Text("Create a macOS workspace to get started. It takes about 15 minutes the first time — future clones take 48 ms.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button {
                onCreate()
            } label: {
                Label("Create Workspace", systemImage: "plus.square.on.square")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .glassProminentButton()
            .controlSize(.large)
            // THE single `glassProminent` on this surface, pinned
            // explicitly to the Apparition accent so the primary
            // action is ember regardless of ancestor tint.
            .tint(Apparition.ember)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // The one-shot entrance drift binds to appearance —
            // the phase animator's `trigger:` variant only cycles
            // when this value changes, so leaving it untouched
            // under Reduce Motion suppresses the motion entirely:
            // <https://developer.apple.com/documentation/SwiftUI/View/phaseAnimator(_:trigger:content:animation:)>
            guard !reduceMotion else { return }
            phase = .lift
        }
    }

    private enum AnimationPhase: Hashable { case drift, lift, settle }
}
