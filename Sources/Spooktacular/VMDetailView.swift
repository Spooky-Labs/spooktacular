import SwiftUI
import SFSymbolsKit
import SpooktacularKit
@preconcurrency import Virtualization

/// Detail view for a selected VM. Simple stack: icon, name,
/// specs, primary + secondary actions.
struct VMDetailView: View {

    let name: String
    let bundle: VirtualMachineBundle

    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRunning: Bool { appState.isRunning(name) }
    private var isTransitioning: Bool { appState.transitioningVMs.contains(name) }

    /// Namespace shared by the hero's Liquid Glass shapes — the
    /// status pill and the Start/Resume action — so their glass
    /// morphs between each other on lifecycle changes. See
    /// ``heroPane``.
    @Namespace private var heroGlass

    /// Drives the wisp halo's light-mode halving in
    /// ``paneAtmosphere`` — the same fog-wants-a-hint rule as
    /// `WorkspaceWindow.wispHalo`.
    @Environment(\.colorScheme) private var colorScheme

    @State private var stats = WorkspaceStatsModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroPane
                if isRunning {
                    statsPane
                        .transition(statsTransition)
                }
                ProvisioningPane(bundle: bundle)
            }
            // 680, up from the old totem-pole's 560: the
            // editorial banner earns its keep by putting the
            // identity cluster and the instrument panel side by
            // side, which needs the extra column width. Purely a
            // presentation cap — `ViewThatFits` in ``heroPane``
            // owns narrow windows.
            .frame(maxWidth: 680)
            .padding(24)
            .frame(maxWidth: .infinity)
            // Bound to the running-state flip (user pressed
            // Start/Stop and the VM actually changed state):
            // springs the stats pane in/out and settles the hero
            // relayout in the app's shared motion voice. Reduce
            // Motion swaps the spring for a short fade-only curve.
            .animation(
                reduceMotion ? .smooth(duration: 0.2) : Apparition.spring,
                value: isRunning
            )
        }
        .navigationTitle(bundle.displayName)
        .task(id: "\(name)-\(isRunning)") {
            // Route stats through the Apple-native
            // `VZVirtioSocketListener` the VM exposes via
            // `agentEventListener()`.
            if isRunning,
               let listener = appState.runningVMs[name]?.agentEventListener() {
                stats.start(listener: listener)
            } else {
                stats.stop()
            }
        }
    }

    // MARK: - Hero card
    //
    // One floating pane over the aurora mesh — no longer a
    // centered totem pole. The hero is an *editorial banner*
    // (leading-aligned identity cluster) facing an *instrument
    // panel* (labeled readouts), the composition this year's ADA
    // winners established: Tide Guide's data-forward readouts
    // under translucent depth, Moonlitt's subject-with-atmosphere
    // framing. Anatomy:
    //
    //   LEFT    identity cluster — the workspace icon (96 pt,
    //           with a static wisp halo glowing beneath the glass
    //           while the VM runs), the VM name in leading-aligned
    //           rounded `.largeTitle`, the small-caps guest-OS
    //           eyebrow BELOW the name, and the status pill
    //           inline under that.
    //   RIGHT   instrument panel — PROCESSOR / MEMORY / STORAGE
    //           (+ GUEST TOOLS on macOS guests) as small-caps
    //           labels over large monospaced values, separated by
    //           hairline `.separator` strokes. Replaces the old
    //           glass spec chips: readouts are content, not
    //           chrome, so they carry no glass.
    //   BOTTOM  the action bar, leading-aligned, spanning the
    //           pane — same buttons, same semantics as ever.
    //
    // `ViewThatFits(in: .horizontal)` (Apple: "selects the first
    // child whose ideal size on the constrained axes fits within
    // the proposed size") steps the banner down at narrow widths
    // instead of clipping — see ``editorialBanner``.
    //
    // The pane itself is unchanged chrome: `.glassEffect(.regular,
    // in:)` on a 28 pt continuous rounded rect, with
    // `.containerShape(.rect(cornerRadius: 28))` still published
    // to descendants — the pane-geometry contract every hero in
    // the app shares, and the anchor any future nested
    // `ConcentricRectangle` resolves against. Behind the glass,
    // ``paneAtmosphere`` adds a
    // top-leading night-wash gradient for depth plus the
    // running-VM wisp halo — both drawn in `.background` so the
    // glass refracts them, the same beneath-the-glass treatment
    // as `WorkspaceWindow`'s wispHalo (whose earlier icon-backed
    // placement bled past the pane bounds).
    //
    // Morph-pair geometry — the WHOLE hero interior now lives in
    // ONE `GlassEffectContainer`, so the status pill (identity
    // cluster, `glassEffectID("status")`) and the Start/Resume
    // button (action bar, `glassEffectID("primaryAction")`)
    // remain shapes of the same container and keep morphing into
    // each other on lifecycle flips. Per Apple's container
    // semantics, glass shapes closer together than the container
    // spacing blend at rest, so:
    //
    //   - container spacing **20** > outer VStack spacing **18**
    //     → the banner (holding the pill) and the action bar stay
    //     inside blending range — the intended Start ⇄ pill
    //     `.matchedGeometry` morph pair, on the same 20/18/24
    //     numbers as before the redesign.
    //   - the action bar's HStack spacing is **24** (see
    //     ``actionBar``), ABOVE the container spacing → adjacent
    //     buttons never merge at rest.
    //   - every other interior stack (banner variants, identity
    //     cluster, instrument panel) holds AT MOST ONE glass
    //     shape — the pill; readouts and text carry no glass —
    //     and blending needs two glass neighbors, so those
    //     tighter spacings cannot fuse anything.

    private var heroPane: some View {
        GlassEffectContainer(spacing: 20) {
            VStack(alignment: .leading, spacing: 18) {
                editorialBanner
                actionBar
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 32)
        .padding(.horizontal, 32)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .containerShape(.rect(cornerRadius: 28))
        .background { paneAtmosphere }
        // Motion bindings — nothing here loops:
        // - `Apparition.spring` fires on ``lifecyclePhase`` changes
        //   (the start/stop/suspend flip): drives the glass morph
        //   and the action-bar button swap.
        // - `Apparition.quick` fires on ``isTransitioning`` changes
        //   (button label ↔ spinner swap while the VM is mid-work).
        // - Reduce Motion replaces both with instant updates.
        .animation(reduceMotion ? nil : Apparition.spring, value: lifecyclePhase)
        .animation(reduceMotion ? nil : Apparition.quick, value: isTransitioning)
        .frame(maxWidth: .infinity)
    }

    /// The responsive identity ⟷ instrument composition.
    ///
    /// `ViewThatFits(in: .horizontal)` tries, in order of
    /// preference:
    /// 1. identity cluster leading, instrument panel trailing;
    /// 2. identity above the panel's row form;
    /// 3. identity above the panel's stacked column form (for the
    ///    narrowest windows).
    ///
    /// Every candidate contains exactly one glass shape — the
    /// status pill inside ``identityCluster`` — so the layout
    /// swap can never fuse or orphan glass, and the pill's
    /// `glassEffectID` stays stable across variants. The swap is
    /// driven by window resizing only (no animation bound to it),
    /// so it is Reduce-Motion-neutral.
    private var editorialBanner: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                identityCluster
                Spacer(minLength: 0)
                instrumentRow
            }
            VStack(alignment: .leading, spacing: 24) {
                identityCluster
                instrumentRow
            }
            VStack(alignment: .leading, spacing: 24) {
                identityCluster
                instrumentColumn
            }
        }
    }

    /// LEFT — the identity cluster, a leading-aligned editorial
    /// column: icon, name, small-caps eyebrow, status pill. State
    /// meaning still lives on the tinted eyebrow and the pill
    /// (the HIG's "color carries meaning once" pattern); the wisp
    /// halo behind the icon is a brand moment, not a state color,
    /// and rides the pane background (see ``paneAtmosphere``).
    private var identityCluster: some View {
        VStack(alignment: .leading, spacing: 14) {
            WorkspaceIconView(
                spec: bundle.metadata.iconSpec ?? .defaultSpec,
                size: 96
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(bundle.displayName)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.leading)
                Text(guestOSLabel)
                    .font(.caption.weight(.semibold).smallCaps())
                    .tracking(1.2)
                    .foregroundStyle(stateTint)
            }

            statusPill
        }
    }

    /// Depth + atmosphere beneath the pane's glass. Two static
    /// layers, clipped to the pane's 28 pt shape so nothing
    /// bleeds past the chrome:
    ///
    /// - a night-wash `LinearGradient` — ``Apparition/night0`` at
    ///   low alpha, deepest at the top-leading corner — giving
    ///   the editorial banner a light direction. No new glass, no
    ///   new colors: night0 is the system's own ground tint.
    /// - the wisp halo — a heavily blurred wisp circle centered
    ///   beneath the workspace icon, visible only while the VM
    ///   runs. Same beneath-the-glass treatment and light-mode
    ///   halving as `WorkspaceWindow.wispHalo`. Static: it holds
    ///   one opacity per state and never loops, so Reduce Motion
    ///   needs no gate here — its appear/disappear rides the
    ///   running-state animation in ``body``, which already swaps
    ///   to a short fade under Reduce Motion.
    private var paneAtmosphere: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Apparition.night0.opacity(0.30), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Apparition.wisp)
                .frame(width: 180, height: 180)
                .blur(radius: 56)
                // Centers the glow under the icon: the icon's
                // center sits at (32 pt padding + 48 pt half-icon)
                // from the pane's top-leading corner; the 180 pt
                // circle's center sits at 90, so nudge by -10.
                .offset(x: -10, y: -10)
                .opacity(
                    isRunning
                        ? (colorScheme == .dark ? 0.18 : 0.10)
                        : 0
                )
        }
        .clipShape(.rect(cornerRadius: 28))
    }

    /// Entrance/exit for the live-stats pane, bound to the
    /// running-state flip. Full motion slides it up from the
    /// bottom edge while fading; Reduce Motion keeps the fade
    /// only.
    private var statsTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .bottom))
    }

    // MARK: - Instrument panel

    /// RIGHT — the instrument panel, row form. Labeled readouts —
    /// a small-caps caption over a large monospaced value —
    /// separated by hairline `.separator` strokes. This replaces
    /// the old glass spec chips: readouts are *content*, so they
    /// carry no glass, and no semantic color (values speak in
    /// neutral primary; only the Guest Tools installed seal earns
    /// vital as success confirmation).
    private var instrumentRow: some View {
        HStack(alignment: .top, spacing: 22) {
            readout("Processor", value: "\(bundle.spec.cpuCount)", unit: "vCPU")
            hairline(.vertical)
            readout("Memory", value: "\(bundle.spec.memorySizeInGigabytes)", unit: "GB")
            hairline(.vertical)
            readout("Storage", value: "\(bundle.spec.diskSizeInGigabytes)", unit: "GB")
            if bundle.spec.guestOS == .macOS {
                hairline(.vertical)
                guestToolsReadout
            }
        }
    }

    /// The panel's stacked form for the narrowest windows — the
    /// same readouts as ``instrumentRow``, one per line, with
    /// horizontal hairlines between them.
    private var instrumentColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            readout("Processor", value: "\(bundle.spec.cpuCount)", unit: "vCPU")
            hairline(.horizontal)
            readout("Memory", value: "\(bundle.spec.memorySizeInGigabytes)", unit: "GB")
            hairline(.horizontal)
            readout("Storage", value: "\(bundle.spec.diskSizeInGigabytes)", unit: "GB")
            if bundle.spec.guestOS == .macOS {
                hairline(.horizontal)
                guestToolsReadout
            }
        }
    }

    /// One labeled readout: a small-caps `.caption2` label above
    /// a large monospaced value, with the unit hung off the
    /// value's first baseline in a smaller monospaced size — the
    /// big-number/small-unit idiom of data-forward instrument
    /// UIs. VoiceOver reads the pair as one element
    /// ("Processor, 4 vCPU").
    private func readout(_ label: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold).smallCaps())
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title2, design: .monospaced).weight(.medium))
                Text(unit)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Guest Tools joins the panel as a fourth readout on macOS
    /// guests, so install state stays *visible* in every
    /// lifecycle state (the old layout only surfaced it through
    /// the install button, which exists only while stopped). The
    /// install BUTTON itself still lives in the action bar,
    /// exactly as before — info here, action there. The filled
    /// seal is the panel's one vital moment: success
    /// confirmation, per the "Night & Wisp" contract.
    private var guestToolsReadout: some View {
        let installed = appState.guestToolsInstalled.contains(name)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Guest Tools")
                .font(.caption2.weight(.semibold).smallCaps())
                .tracking(0.8)
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: installed ? String.SFSymbols.checkmarkSealFill : String.SFSymbols.seal)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(
                        installed
                            ? AnyShapeStyle(Apparition.vital)
                            : AnyShapeStyle(.secondary)
                    )
                Text(installed ? "Installed" : "Not Installed")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(
                        installed
                            ? AnyShapeStyle(.primary)
                            : AnyShapeStyle(.secondary)
                    )
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Divider orientation for ``hairline(_:)``.
    private enum HairlineAxis { case horizontal, vertical }

    /// A fine `.separator` stroke — the instrument panel's
    /// divider language. 1 pt, in SwiftUI's semantic separator
    /// style ("a style appropriate for foreground separator or
    /// border lines"), so it adapts to both appearances for free.
    /// Vertical hairlines take a fixed 40 pt run (the height of a
    /// label + value pair); horizontal ones span the column.
    private func hairline(_ axis: HairlineAxis) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .vertical ? 40 : 1
            )
    }

    /// BOTTOM — the action bar, leading-aligned under the banner
    /// (the enclosing VStack in ``heroPane`` is leading-aligned),
    /// inside the hero's shared `GlassEffectContainer`. Its
    /// HStack spacing is **24** — deliberately ABOVE the
    /// container's spacing of 20 — so adjacent buttons never
    /// blend into one fused shape at rest. Every button label
    /// carries ``hoverSymbolBounce()`` (a one-shot,
    /// Reduce-Motion-gated symbol bounce on pointer entry).
    ///
    /// The Start/Resume button is the Apparition signature. It
    /// carries an explicit wisp-tinted `glassEffect(_:in:)` plus
    /// `glassEffectID(_:in:)` and
    /// `glassEffectTransition(.matchedGeometry)`. When starting
    /// succeeds, `isRunning` flips, the button leaves the
    /// hierarchy, and its glass morphs into the status pill — the
    /// pill that now reads "Running" in vital. Stopping runs the
    /// same morph in reverse: the pill births the Start button.
    /// Only this button and the pill carry `glassEffect`, so the
    /// container's morph can't pair with a neighboring button.
    ///
    /// Tint mapping ("Night & Wisp" contract — the accent is
    /// spent exactly once per state):
    ///   - wisp → the single primary action for the current state
    ///     (Open Workspace via ``glassProminentButton()`` when
    ///     running; the Start/Resume glass morph when stopped —
    ///     the prominent style carries the wisp itself, no manual
    ///     `.tint` needed)
    ///   - vital → success confirmation (Guest Tools Installed)
    ///   - neutral → everything else, including Stop: its
    ///     destructive meaning lives in the hard-stop help text,
    ///     not in a red fill that would fight the surface's
    ///     single-accent budget
    private var actionBar: some View {
        let transitioning = appState.transitioningVMs.contains(name)
        let suspended = !isRunning && appState.isSuspended(name)

        return HStack(spacing: 24) {
            openWorkspaceButton

            if isRunning {
                Button {
                    Task { await appState.suspendVM(name) }
                } label: {
                    if transitioning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suspend", systemImage: String.SFSymbols.pauseCircle)
                            .hoverSymbolBounce()
                    }
                }
                .glassButton()
                .controlSize(.large)
                .disabled(transitioning)
                .help("Save VM state and quit. Next start picks up exactly where you left off.")

                Button {
                    Task { await appState.stopVM(name) }
                } label: {
                    Label("Stop", systemImage: String.SFSymbols.stopCircle)
                        .hoverSymbolBounce()
                }
                .glassButton()
                .controlSize(.large)
                .disabled(transitioning)
                .help("Hard-stop the VM. The guest doesn't get a chance to flush state — use Suspend for graceful.")
            } else {
                Button {
                    Task { await appState.startVM(name) }
                } label: {
                    Group {
                        if transitioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                suspended ? "Resume" : "Start",
                                systemImage: suspended
                                    ? String.SFSymbols.playCircleFill
                                    : String.SFSymbols.playCircle
                            )
                            .hoverSymbolBounce()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(Apparition.wisp).interactive(),
                    in: .capsule
                )
                .glassEffectID("primaryAction", in: heroGlass)
                .glassEffectTransition(.matchedGeometry)
                .disabled(transitioning)
                .help(suspended
                    ? "Restore from the saved state and continue exactly where you left off."
                    : "Cold-boot the VM.")

                if bundle.spec.guestOS == .macOS {
                    let installed = appState.guestToolsInstalled.contains(name)
                    Button {
                        appState.installGuestTools(name)
                    } label: {
                        if transitioning {
                            ProgressView().controlSize(.small)
                        } else if installed {
                            Label("Guest Tools Installed", systemImage: String.SFSymbols.checkmarkSealFill)
                                .hoverSymbolBounce()
                        } else {
                            Label("Install Guest Tools", systemImage: String.SFSymbols.arrowDownToLineCircle)
                                .hoverSymbolBounce()
                        }
                    }
                    .glassButton()
                    .controlSize(.large)
                    .tint(installed ? Apparition.vital : nil)
                    .disabled(transitioning)
                    .help(installed
                        ? "Spooktacular Guest Tools are already installed. Click to reinstall — idempotent and safe."
                        : "Install Spooktacular Guest Tools (clipboard bridge + guest-agent API) into /Applications and auto-launch at first login. Requires admin password once.")
                }
            }
        }
    }

    /// Open Workspace — the ONE prominent (wisp) button on this
    /// surface while the VM is running: opening the live display
    /// is a running VM's primary action, and
    /// ``glassProminentButton()`` carries the accent itself (no
    /// manual `.tint`). While stopped it demotes to neutral
    /// `.glassButton()` — Start/Resume owns the wisp moment then,
    /// keeping the one-accent-per-surface budget.
    @ViewBuilder
    private var openWorkspaceButton: some View {
        let button = Button {
            openWindow(id: "workspace", value: name)
        } label: {
            Label("Open Workspace", systemImage: String.SFSymbols.macwindow)
                .hoverSymbolBounce()
        }
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [])

        if isRunning {
            button.glassProminentButton()
        } else {
            button.glassButton()
        }
    }

    /// Glass pill showing the current lifecycle state. A single
    /// `Image` whose glyph and color derive from ``lifecyclePhase``,
    /// so the glyph morphs between states with
    /// `.contentTransition(.symbolEffect(.replace))` (Apple:
    /// `ContentTransition.symbolEffect(_:options:)` — the Replace
    /// animation for symbol images; it only fires inside an
    /// animation context, which the scoped `.animation(_:value:)`
    /// supplies). While the VM is mid-transition (booting /
    /// installing / suspending) the glyph pulses lantern via
    /// `.symbolEffect(.pulse, isActive:)` — the one looping effect
    /// here, active only while the system is genuinely mid-work
    /// and suppressed entirely under Reduce Motion.
    /// Only the glyph carries the semantic color; text stays
    /// neutral against the capsule, per the HIG's "color carries
    /// meaning once" pattern.
    ///
    /// The pill is the persistent glass shape of the hero's morph
    /// pair: it carries `.glassEffect` + `.glassEffectID` in
    /// ``heroGlass`` so the Start/Resume button's glass can morph
    /// into it when the VM starts (see ``actionBar``).
    private var statusPill: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSymbol)
                .font(.system(size: statusSymbolSize))
                .foregroundStyle(statusSymbolColor)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: isTransitioning && !reduceMotion)
                .animation(
                    reduceMotion ? nil : Apparition.spring,
                    value: lifecyclePhase
                )
            Text(statusLabel)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .glassEffectID("status", in: heroGlass)
    }

    // MARK: - Derived state

    /// The three settled lifecycle states the status pill renders.
    /// Transitional booting/installing is signalled by pulsing the
    /// glyph (see ``statusPill``), not by a separate phase.
    private enum LifecyclePhase: Equatable { case running, suspended, stopped }

    private var lifecyclePhase: LifecyclePhase {
        if isRunning { return .running }
        if appState.isSuspended(name) { return .suspended }
        return .stopped
    }

    /// Leading glyph for the status pill. Swapping this value
    /// drives the `.symbolEffect(.replace)` content transition.
    private var statusSymbol: String {
        switch lifecyclePhase {
        case .running: String.SFSymbols.circleFill
        case .suspended: String.SFSymbols.pauseCircleFill
        case .stopped: String.SFSymbols.circle
        }
    }

    private var statusSymbolSize: CGFloat {
        switch lifecyclePhase {
        case .suspended: 10
        case .running, .stopped: 8
        }
    }

    /// Semantic glyph color per the "Night & Wisp" palette:
    /// lantern while mid-transition (booting / suspending /
    /// installing — in-progress) or suspended (a saved, dormant
    /// glow), vital when running (alive), neutral when stopped.
    /// Never wisp — the accent marks actions, not states.
    private var statusSymbolColor: AnyShapeStyle {
        if isTransitioning { return AnyShapeStyle(Apparition.lantern) }
        switch lifecyclePhase {
        case .running: return AnyShapeStyle(Apparition.vital)
        case .suspended: return AnyShapeStyle(Apparition.lantern)
        case .stopped: return AnyShapeStyle(.secondary)
        }
    }

    private var statusLabel: String {
        switch lifecyclePhase {
        case .running: "Running"
        case .suspended: "Suspended"
        case .stopped: "Stopped"
        }
    }

    /// State-driven tint for the title eyebrow, matching
    /// ``statusSymbolColor``: vital for running (alive), lantern
    /// for in-progress or suspended, neutral secondary for stopped
    /// (no alarm, just "not running"). Same signal in both places,
    /// same colors — the eyebrow and the pill glyph always agree.
    private var stateTint: AnyShapeStyle {
        if isTransitioning { return AnyShapeStyle(Apparition.lantern) }
        if isRunning { return AnyShapeStyle(Apparition.vital) }
        if appState.isSuspended(name) { return AnyShapeStyle(Apparition.lantern) }
        return AnyShapeStyle(.secondary)
    }

    /// Small-caps eyebrow below the title — "macOS Virtual
    /// Machine" or "Linux Virtual Machine", rendered in all small
    /// capitals by `Font.smallCaps()`. Gives the hero a secondary
    /// readable label that doesn't compete with the VM name for
    /// visual weight.
    private var guestOSLabel: String {
        switch bundle.spec.guestOS {
        case .macOS: "macOS Virtual Machine"
        case .linux: "Linux Virtual Machine"
        }
    }

    // MARK: - Live stats (Swift Charts)

    private var statsPane: some View {
        WorkspaceStatsSidebar(model: stats)
            .frame(maxWidth: .infinity)
    }
}

/// `NSViewRepresentable` wrapping a **pre-created**
/// `VZVirtualMachineView` so a running VM's framebuffer hosts
/// inside a SwiftUI view without the start-before-attach race.
///
/// The view is owned by `AppState.graphicsViews[name]`,
/// created + wired to the VM in `AppState.startVM` **before**
/// `vm.startOrResume()` — matches Apple's canonical order in
/// the "Running macOS in a Virtual Machine" sample:
/// create VM → set delegate → `view.virtualMachine = vm` →
/// configure → start.
///
/// The cached view is passed in **explicitly** as an init
/// parameter (not read from `@Environment` inside `makeNSView`)
/// — `NSViewRepresentable`'s environment hydration has timing
/// gotchas and can return a fresh AppState instance whose
/// `graphicsViews` dict is empty, which silently falls back to
/// the late-attach path we're trying to avoid.
struct VMDisplayView: NSViewRepresentable {

    let name: String
    let virtualMachine: VirtualMachine
    let cachedView: VZVirtualMachineView?

    func makeNSView(context: Context) -> VZVirtualMachineView {
        if let cached = cachedView {
            return cached
        }
        // Fallback — state was stripped (VM deleted / remote
        // mutation). Re-create to avoid crashing; the
        // late-attach race can re-appear in this path but it's
        // better than a nil-dereference.
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine.vzVM
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.setAccessibilityLabel("Virtual machine display for \(name)")
        view.setAccessibilityRole(.group)
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        if nsView.virtualMachine !== virtualMachine.vzVM {
            nsView.virtualMachine = virtualMachine.vzVM
        }
    }
}

/// Detail view for a selected image in the Images section.
///
/// A Liquid Glass "hero card" sharing ``VMDetailView``'s
/// editorial anatomy so the two detail surfaces read as one
/// system: identity cluster leading (medallion, name, small-caps
/// kind eyebrow), instrument-style metadata readouts trailing,
/// actions leading-aligned below, with `ViewThatFits` stacking
/// identity above the readouts at narrow widths. The pane floats
/// over the aurora, so it's chrome — `.glassEffect(.regular,
/// in:)` on a 28pt continuous rounded rect, with
/// `.containerShape(.rect(cornerRadius: 28))` still published to
/// descendants. The image-kind tint (IPSW = Apple blue,
/// ISO = Tux gold, OCI = purple) carries semantic weight in
/// exactly three places: the eyebrow text, the medallion's color
/// fill, and a 6% tint on the pane's glass — the metadata
/// readouts stay neutral on purpose so the contract holds. The
/// action bar's single `glassProminent` button carries the wisp
/// accent via `glassProminentButton()`.
struct ImageDetailView: View {

    let image: VirtualMachineImage
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            heroCard
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(image.name)
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Same responsive step-down as the VM hero: identity
            // beside the readouts when the name and source both
            // fit, identity above them otherwise. Neither
            // candidate holds any glass shape, so the swap has no
            // blending consequences.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    identityCluster
                    Spacer(minLength: 0)
                    metadataPanel
                }
                VStack(alignment: .leading, spacing: 24) {
                    identityCluster
                    metadataPanel
                }
            }
            actionBar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 32)
        .padding(.horizontal, 32)
        .frame(maxWidth: 680)
        .glassEffect(
            .regular.tint(tintColor.opacity(0.06)),
            in: .rect(cornerRadius: 28)
        )
        .containerShape(.rect(cornerRadius: 28))
        .frame(maxWidth: .infinity)
    }

    /// LEFT — the identity cluster, matching ``VMDetailView``'s:
    /// medallion, leading-aligned name, small-caps kind eyebrow
    /// below it. The eyebrow is tint place 1 of 3.
    private var identityCluster: some View {
        VStack(alignment: .leading, spacing: 14) {
            iconMedallion

            VStack(alignment: .leading, spacing: 4) {
                Text(image.name)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.leading)
                Text(sourceKindLabel)
                    .font(.caption.weight(.semibold).smallCaps())
                    .tracking(1.2)
                    .foregroundStyle(tintColor)
            }
        }
    }

    /// Circular medallion around the SF Symbol. A plain
    /// color-gradient fill (`Color.gradient` — "the standard
    /// gradient for the color") in the hero's kind tint: the
    /// medallion is content-layer imagery, so it gets a color
    /// fill, not Liquid Glass. The saturated disc is where the
    /// kind color speaks loudest (tint place 2 of 3); the pane
    /// wash and eyebrow only echo it. 96 pt — the same identity
    /// scale as the VM hero's workspace icon.
    private var iconMedallion: some View {
        Image(systemName: iconName)
            .font(.system(size: 46, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(tintColor.gradient, in: .circle)
            .accessibilityHidden(true)
    }

    /// RIGHT — the metadata, reshaped into the labeled-readout
    /// language shared with ``VMDetailView``'s instrument panel:
    /// a small-caps caption label (keeping its original SF
    /// Symbol) above each value, hairline `.separator` strokes
    /// between rows. The content is exactly the old grid's:
    ///
    /// - **Source** — the IPSW's `lastPathComponent` or the full
    ///   OCI reference, monospaced and selectable so it can be
    ///   copied into a terminal; `.middle` truncation preserves
    ///   both ends (build number + extension) of long names.
    /// - **Size** — `ByteCountFormatStyle`, `.file` counting so
    ///   the number matches Finder.
    /// - **Added** — absolute date with a relative caption
    ///   underneath ("May 3, 2026" / "2 months ago"): the
    ///   absolute answers audits, the relative answers "is this
    ///   stale?" at a glance.
    ///
    /// Readouts are content — no glass (the old nested glass chip
    /// is gone; chips are chrome, data is not) and NO kind tint:
    /// the three-places tint contract lives in the eyebrow,
    /// medallion, and pane wash only.
    private var metadataPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                panelLabel("Source", systemImage: sourceIcon)
                Text(sourceDetailLabel)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)

            if let bytes = image.sizeInBytes {
                panelHairline
                VStack(alignment: .leading, spacing: 4) {
                    panelLabel("Size", systemImage: String.SFSymbols.internaldrive)
                    Text(Int64(clamping: bytes), format: .byteCount(style: .file))
                        .font(.system(.title3, design: .monospaced).weight(.medium))
                }
                .accessibilityElement(children: .combine)
            }

            panelHairline
            VStack(alignment: .leading, spacing: 4) {
                panelLabel("Added", systemImage: String.SFSymbols.calendar)
                Text(image.addedAt, format: .dateTime.day().month(.wide).year())
                    .font(.callout)
                    .monospacedDigit()
                Text(image.addedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// A readout label — small-caps `.caption2`, secondary, with
    /// the row's original SF Symbol riding along at label scale.
    private func panelLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold).smallCaps())
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }

    /// A fine `.separator` hairline between readout rows. Fixed
    /// 220 pt run so the readout column keeps its natural width
    /// instead of greedily stretching across the pane.
    private var panelHairline: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 220, height: 1)
    }

    /// Action bar — leading-aligned under the banner (the hero's
    /// enclosing VStack is leading-aligned), matching the VM
    /// hero's anatomy. Container spacing **8** stays BELOW the
    /// HStack's **12**, so the two buttons never merge at rest
    /// (this pane never had the blob bug; keep it that way).
    private var actionBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    // Route to the correct pre-seed channel
                    // based on file extension:
                    //   .iso  → Linux installer path (guestOS
                    //           becomes .linux in the sheet)
                    //   else  → macOS IPSW path (guestOS stays
                    //           .macOS)
                    // OCI images have no filesystem path; the
                    // sheet opens without any pre-seed so the
                    // user can choose.
                    if case .ipsw(let path) = image.source {
                        if path.lowercased().hasSuffix(".iso") {
                            appState.pendingCreateISOPath = path
                        } else {
                            appState.pendingCreateIpswPath = path
                        }
                    }
                    appState.showCreateSheet = true
                } label: {
                    Label("Create VM from image", systemImage: String.SFSymbols.plusSquareOnSquare)
                        .hoverSymbolBounce()
                        .padding(.horizontal, 8)
                }
                .glassProminentButton()
                .controlSize(.large)

                Button(role: .destructive) {
                    try? appState.imageLibrary.remove(id: image.id)
                } label: {
                    Label("Delete", systemImage: String.SFSymbols.trash)
                        .hoverSymbolBounce()
                }
                .glassButton()
                .controlSize(.large)
            }
        }
    }

    // MARK: - Derived (image-kind detection)

    /// Three visual flavors of the image hero: macOS IPSW,
    /// Linux ISO, or OCI reference. The `VirtualMachineImage`
    /// enum only distinguishes `.ipsw` vs `.oci` today, so we
    /// disambiguate Linux ISOs from macOS IPSWs by looking at
    /// the file extension. Any local file ending in `.iso` is
    /// treated as Linux — there's no other vendor that ships
    /// ARM64 OS install media as a plain `.iso` for consumption
    /// by `VZEFIBootLoader`.
    private enum HeroKind { case macOS, linux, oci }

    private var kind: HeroKind {
        switch image.source {
        case .ipsw(let path):
            return (path.lowercased().hasSuffix(".iso")) ? .linux : .macOS
        case .oci:
            return .oci
        }
    }

    /// The large white glyph inside the medallion. `apple.logo`
    /// for macOS IPSWs (unambiguous Apple-provenance cue);
    /// `opticaldisc.fill` for Linux ISOs (thematic — ISO is
    /// literally a disc image); `cube.transparent` for OCI
    /// references (container ecosystem iconography).
    private var iconName: String {
        switch kind {
        case .macOS: String.SFSymbols.appleLogo
        case .linux: String.SFSymbols.opticaldiscFill
        case .oci: String.SFSymbols.cubeTransparent
        }
    }

    /// Small SF Symbol in the source-detail chip.
    private var sourceIcon: String {
        switch kind {
        case .macOS: String.SFSymbols.zipperPage
        case .linux: String.SFSymbols.opticaldisc
        case .oci: String.SFSymbols.shippingbox
        }
    }

    /// Uppercased eyebrow label under the title.
    private var sourceKindLabel: String {
        switch kind {
        case .macOS: "Local IPSW"
        case .linux: "Linux ISO"
        case .oci: "OCI Image"
        }
    }

    private var sourceDetailLabel: String {
        switch image.source {
        case .ipsw(let path):
            (path as NSString).lastPathComponent
        case .oci(let reference):
            reference
        }
    }

    /// Mascot/classic palette — semantic colors rooted in
    /// each ecosystem's own iconography rather than the
    /// generic system palette:
    ///
    /// - **macOS IPSW** → Apple's system blue (`Color.blue`).
    ///   Matches Apple's own marketing + the `apple.logo`
    ///   glyph's canonical default color.
    /// - **Linux ISO** → Tux-gold `#FFCC33`. The color of
    ///   Tux the Penguin's beak and feet — the only Linux
    ///   color that's genuinely shared across every distro,
    ///   not co-opted from a specific one (Ubuntu orange,
    ///   Fedora blue, Debian red all spoken for).
    /// - **OCI** → purple. Keeps the container ecosystem
    ///   visually distinct from both Apple blue and Tux gold.
    private var tintColor: Color {
        switch kind {
        case .macOS: .blue
        case .linux: Color(red: 1.0, green: 0.8, blue: 0.2)   // #FFCC33
        case .oci: .purple
        }
    }
}

/// Sidebar row for one VM — state medallion, name, spec caption,
/// hover quick-action.
///
/// `name` is the `vms` dictionary key (the bundle's UUID string),
/// not a label — it's only used to look up the bundle and to
/// drive lifecycle actions. Everything actually rendered comes
/// from ``VirtualMachineBundle/displayName``.
///
/// The row leads with state: a compact circle-family medallion
/// whose color speaks the Apparition state language —
/// ``Apparition/vital`` running, ``Apparition/lantern``
/// transitioning (pulsing), quiet secondary stopped. The glyph
/// swap animates with `.contentTransition(.symbolEffect(.replace))`
/// scoped to the glyph value; the pulse is state-bound via
/// `.symbolEffect(.pulse, isActive:)`. Both are Reduce-Motion
/// gated.
///
/// Hovering the row fades in a trailing quick-action glyph —
/// play when stopped, stop when running — that calls the same
/// ``AppState/startVM(_:recovery:guestProvisioning:)`` /
/// ``AppState/stopVM(_:)`` methods the detail view uses. The
/// fade is the only hover motion and is skipped under Reduce
/// Motion (the button still appears, instantly).
struct VMRow: View {

    let name: String
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var bundle: VirtualMachineBundle? { appState.vms[name] }
    private var isRunning: Bool { appState.isRunning(name) }
    private var isTransitioning: Bool { appState.transitioningVMs.contains(name) }

    /// One family of circle glyphs so `.replace` reads as a
    /// state change, not an icon swap: dotted while
    /// materializing (transitioning), inset-filled while alive,
    /// hollow at rest.
    private var stateGlyph: String {
        if isTransitioning {
            String.SFSymbols.circleDotted
        } else if isRunning {
            String.SFSymbols.insetFilledCircle
        } else {
            String.SFSymbols.circle
        }
    }

    private var stateColor: Color {
        if isTransitioning {
            Apparition.lantern
        } else if isRunning {
            Apparition.vital
        } else {
            Color.secondary.opacity(0.45)
        }
    }

    private var stateLabel: String {
        if isTransitioning {
            "transitioning"
        } else if isRunning {
            "running"
        } else {
            "stopped"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: stateGlyph)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(stateColor)
                .frame(width: 16)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: isTransitioning && !reduceMotion)
                .animation(reduceMotion ? nil : Apparition.quick, value: stateGlyph)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(bundle?.displayName ?? name).font(.body)
                if let bundle {
                    Text(specCaption(for: bundle))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            // Quick action: hidden while transitioning (both
            // lifecycle methods no-op mid-transition anyway, so
            // showing a dead control would lie). Opacity keeps
            // the row layout stable; hit-testing follows
            // visibility so an invisible button can't steal the
            // selection click.
            if !isTransitioning {
                Button {
                    if isRunning {
                        Task { await appState.stopVM(name) }
                    } else {
                        Task { await appState.startVM(name) }
                    }
                } label: {
                    Image(systemName: isRunning ? String.SFSymbols.stopFill : String.SFSymbols.playFill)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .help(isRunning ? "Stop this workspace" : "Start this workspace")
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(reduceMotion ? nil : Apparition.quick, value: isHovering)
                .animation(reduceMotion ? nil : Apparition.quick, value: isRunning)
                .accessibilityLabel(
                    isRunning
                        ? "Stop \(bundle?.displayName ?? name)"
                        : "Start \(bundle?.displayName ?? name)"
                )
            }
        }
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    /// "macOS · 4 vCPU · 8 GB" — guest OS first so heterogeneous
    /// fleets scan by platform, then the two numbers people
    /// actually compare (monospaced digits keep columns steady
    /// across rows).
    private func specCaption(for bundle: VirtualMachineBundle) -> String {
        let os: String
        switch bundle.spec.guestOS {
        case .macOS: os = "macOS"
        case .linux: os = "Linux"
        }
        return "\(os) · \(bundle.spec.cpuCount) vCPU · \(bundle.spec.memorySizeInGigabytes) GB"
    }
}

/// Sidebar row for an in-flight VM creation.
///
/// Renders while `AppState.pendingCreations[name]` is populated —
/// during the IPSW download, install, and disk-inject phases (or
/// the Linux disk + ISO copy path). Mirrors ``VMRow``'s layout so
/// the sidebar doesn't jump when the row flips from pending →
/// live on `loadVMs()` pickup.
///
/// Three states:
///
/// - **In progress** — orange state dot (matching the
///   `transitioningVMs` convention in the menu bar), linear
///   `ProgressView(value:)` bound to `pending.progress`, status
///   message underneath, cancel button on trailing edge.
/// - **Errored** — the row stays in the sidebar so the user can
///   read the failure; the cancel glyph flips to a dismiss glyph
///   that calls ``AppState/dismissPending(_:)``.
/// - **Indeterminate** — `progress == 0` renders an
///   indeterminate bar so "Queued…" doesn't look frozen.
struct PendingVMRow: View {

    let pending: AppState.PendingCreation
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasError: Bool { pending.errorMessage != nil }

    private var percentLabel: String? {
        guard !hasError, pending.progress > 0 else { return nil }
        return "\(Int(pending.progress * 100))%"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Lantern while creating (the Apparition in-progress
            // color, matching the transitioning / suspended
            // convention); red when errored so the row reads as
            // a failure at a glance.
            Image(systemName: String.SFSymbols.circleFill)
                .font(.system(size: 7))
                .foregroundStyle(hasError ? .red : Apparition.lantern)
                // The lantern breathes while work is in flight —
                // the same in-progress pulse `VMRow` uses for its
                // transitioning state. State-bound (stops the
                // moment the row flips to errored) and skipped
                // under Reduce Motion.
                .symbolEffect(.pulse, isActive: !hasError && !reduceMotion)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(pending.name)
                        .font(.body)
                    Text(pending.guestOSLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    if let percentLabel {
                        Text(percentLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if !hasError {
                    // `ProgressView(value: V?)` — Apple's
                    // canonical form: a nil value produces an
                    // indeterminate bar, a non-nil value
                    // produces a determinate bar. Keeping one
                    // view (not two branches) preserves
                    // SwiftUI view identity so the bar
                    // animates smoothly when the first real
                    // progress update lands.
                    //
                    // See ProgressView.init(value:total:) —
                    // "A value of `nil` represents
                    // indeterminate progress, in which case
                    // the progress view ignores `total`."
                    ProgressView(
                        value: pending.progress > 0 ? pending.progress : nil,
                        total: 1.0
                    )
                    .progressViewStyle(.linear)
                    .tint(Apparition.lantern)
                    .controlSize(.small)
                }

                Text(pending.errorMessage ?? pending.statusMessage)
                    .font(.caption)
                    .foregroundStyle(hasError ? .red : .secondary)
                    .lineLimit(2)
            }

            Button {
                if hasError {
                    appState.dismissPending(pending.name)
                } else {
                    appState.cancelPending(pending.name)
                }
            } label: {
                Image(systemName: hasError ? String.SFSymbols.xmarkCircleFill : String.SFSymbols.stopCircle)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(hasError ? "Dismiss" : "Cancel")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            hasError
                ? "Creation of \(pending.name) failed: \(pending.errorMessage ?? "")"
                : "Creating \(pending.name), \(Int(pending.progress * 100)) percent, \(pending.statusMessage)"
        )
    }
}
