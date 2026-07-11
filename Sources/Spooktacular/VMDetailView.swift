import SwiftUI
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
    /// ``statusAndActions``.
    @Namespace private var heroGlass

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
            .frame(maxWidth: 560)
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
    // One rounded-rect content pane on a standard
    // `.regularMaterial` background — per the macOS HIG's "don't
    // use Liquid Glass in the content layer" guidance, an elevated
    // detail card belongs on a system material, not on a glass
    // surface (glass is reserved for the navigation / control
    // layer). The material carries a low-alpha Apparition ground
    // wash (``ApparitionPaneBackground``) that biases it toward
    // the "Night & Ember" palette without replacing it. Lifecycle
    // state is carried by the tinted eyebrow (2) and the status
    // pill (4) — vital when running, lantern while suspended or
    // mid-transition — so the pane itself stays neutral chrome.
    // Inside, a top-to-bottom stack:
    //
    //   1. Icon medallion — keeps the user's custom icon front
    //      and center.
    //   2. Title + uppercased, state-tinted eyebrow.
    //   3. Spec chips (CPU / RAM / Disk) — `.regularMaterial`
    //      capsules with SF-Symbol leading glyphs.
    //   4. Status pill + action bar in one `GlassEffectContainer`
    //      (``statusAndActions``): the Start/Resume button and the
    //      pill share the ``heroGlass`` namespace so starting the
    //      VM morphs the button's glass into the pill.
    //
    // The whole pane follows the same aesthetic as
    // `ImageDetailView.heroCard`, so the library feels
    // coherent across selection types (VM vs Image).

    private var heroPane: some View {
        VStack(spacing: 24) {
            iconMedallion
            titleBlock
            specChips
            statusAndActions
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 32)
        .frame(maxWidth: 640)
        .background { ApparitionPaneBackground(cornerRadius: 24) }
        .frame(maxWidth: .infinity)
    }

    /// The hero's Liquid Glass cluster — status pill above the
    /// action bar, wrapped in **one** `GlassEffectContainer` so
    /// the two shapes that carry `glassEffect` (the pill and the
    /// Start/Resume button, see ``actionBar``) can morph into each
    /// other. Mirrors Apple's pencil/note example for
    /// `glassEffectTransition(_:)`: the container spacing matches
    /// the interior stack spacing, the persistent shape (the pill)
    /// and the appearing/disappearing shape (Start/Resume) each
    /// carry a `glassEffectID(_:in:)` in ``heroGlass``.
    ///
    /// Motion bindings — nothing here loops:
    /// - `Apparition.spring` fires on ``lifecyclePhase`` changes
    ///   (the start/stop/suspend flip): drives the glass morph and
    ///   the action-bar button swap.
    /// - `Apparition.quick` fires on ``isTransitioning`` changes
    ///   (button label ↔ spinner swap while the VM is mid-work).
    /// - Reduce Motion replaces both with instant updates.
    private var statusAndActions: some View {
        GlassEffectContainer(spacing: 24) {
            VStack(spacing: 24) {
                statusPill
                actionBar
            }
        }
        .animation(reduceMotion ? nil : Apparition.spring, value: lifecyclePhase)
        .animation(reduceMotion ? nil : Apparition.quick, value: isTransitioning)
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

    /// The user's custom `WorkspaceIconView`. State meaning lives
    /// on the tinted eyebrow and the status pill — per the HIG's
    /// "color carries meaning once" pattern, adding a colored glow
    /// shadow on the icon itself would just repeat the same signal.
    private var iconMedallion: some View {
        WorkspaceIconView(
            spec: bundle.metadata.iconSpec ?? .defaultSpec,
            size: 140
        )
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(bundle.displayName)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text(guestOSLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateTint)
                .textCase(.uppercase)
                .tracking(1.2)
        }
    }

    /// CPU / RAM / Disk spec chips — three `.regularMaterial`
    /// capsules. Each chip carries a category-specific SF Symbol
    /// so the scanning eye reads the numbers + their meaning
    /// simultaneously. Material (not glass) keeps these
    /// content-layer chips off the reserved Liquid Glass layer.
    private var specChips: some View {
        HStack(spacing: 12) {
            specChip(
                systemImage: "cpu",
                text: "\(bundle.spec.cpuCount) CPU"
            )
            specChip(
                systemImage: "memorychip",
                text: "\(bundle.spec.memorySizeInGigabytes) GB"
            )
            specChip(
                systemImage: "internaldrive",
                text: "\(bundle.spec.diskSizeInGigabytes) GB"
            )
        }
    }

    private func specChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }

    /// Action bar inside the hero's shared `GlassEffectContainer`
    /// (see ``statusAndActions``). Secondary buttons are
    /// `.glassButton()` so they share one visual weight; semantic
    /// emphasis comes from `.tint(...)`, not from a different fill
    /// style.
    ///
    /// The Start/Resume button is the exception — the Apparition
    /// signature. It carries an explicit ember-tinted
    /// `glassEffect(_:in:)` (the ONE ember/prominent moment on
    /// this surface) plus `glassEffectID(_:in:)` and
    /// `glassEffectTransition(.matchedGeometry)`. When starting
    /// succeeds, `isRunning` flips, the button leaves the
    /// hierarchy, and its glass morphs into the status pill — the
    /// pill that now reads "Running" in vital. Stopping runs the
    /// same morph in reverse: the pill births the Start button.
    /// Only this button and the pill carry `glassEffect`, so the
    /// container's morph can't pair with a neighboring button.
    ///
    /// Tint mapping ("Night & Ember" contract):
    ///   - ember → the primary action for the current state
    ///     (Start/Resume when stopped; Open Workspace inherits the
    ///     ember app accent when running)
    ///   - vital → success confirmation (Guest Tools Installed)
    ///   - red → hard-stop (system destructive convention)
    ///   - neutral → everything else
    private var actionBar: some View {
        let transitioning = appState.transitioningVMs.contains(name)
        let suspended = !isRunning && appState.isSuspended(name)

        return HStack(spacing: 10) {
            Button {
                openWindow(id: "workspace", value: name)
            } label: {
                Label("Open Workspace", systemImage: "macwindow")
            }
            .glassButton()
            .controlSize(.large)
            .tint(isRunning ? .accentColor : nil)
            .keyboardShortcut(.return, modifiers: [])

            if isRunning {
                Button {
                    Task { await appState.suspendVM(name) }
                } label: {
                    if transitioning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suspend", systemImage: "pause.circle")
                    }
                }
                .glassButton()
                .controlSize(.large)
                .disabled(transitioning)
                .help("Save VM state and quit. Next start picks up exactly where you left off.")

                Button {
                    Task { await appState.stopVM(name) }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                }
                .glassButton()
                .controlSize(.large)
                .tint(.red)
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
                                systemImage: suspended ? "play.circle.fill" : "play.circle"
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(
                    .regular.tint(Apparition.ember).interactive(),
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
                            Label("Guest Tools Installed", systemImage: "checkmark.seal.fill")
                        } else {
                            Label("Install Guest Tools", systemImage: "arrow.down.to.line.circle")
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
        case .running: "circle.fill"
        case .suspended: "pause.circle.fill"
        case .stopped: "circle"
        }
    }

    private var statusSymbolSize: CGFloat {
        switch lifecyclePhase {
        case .suspended: 10
        case .running, .stopped: 8
        }
    }

    /// Semantic glyph color per the "Night & Ember" palette:
    /// lantern while mid-transition (booting / suspending /
    /// installing — in-progress) or suspended (a saved, dormant
    /// ember), vital when running (alive), neutral when stopped.
    /// Never ember — the accent marks actions, not states.
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

    /// Uppercased eyebrow under the title — "macOS VIRTUAL
    /// MACHINE" or "LINUX VIRTUAL MACHINE". Gives the hero a
    /// secondary readable label that doesn't compete with the
    /// VM name for visual weight.
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

/// The Apparition hero-pane ground: a `.regularMaterial`
/// rounded rect (content layer stays on system materials per the
/// HIG — never Liquid Glass) with a low-alpha "Night & Ember"
/// wash layered **over** the material. The wash is a night2 →
/// night1 vertical gradient that biases the system material
/// toward the séance-room palette without replacing it; in the
/// light ("Fog") appearance the same tints read as a faint lift.
/// An optional `tint` adds a whisper (6%) of a semantic hue for
/// heroes that carry a kind color (see `ImageDetailView`).
///
/// Static by design — a ground never animates on its own.
private struct ApparitionPaneBackground: View {

    /// Corner radius of the pane; matches the hero card shape.
    var cornerRadius: CGFloat = 24

    /// Optional semantic hue washed over the ground at 6% alpha.
    var tint: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(.regularMaterial)
            .overlay {
                shape.fill(
                    LinearGradient(
                        colors: [
                            Apparition.night2.opacity(0.30),
                            Apparition.night1.opacity(0.12),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .overlay {
                if let tint {
                    shape.fill(tint.opacity(0.06))
                }
            }
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
/// A material "hero card" mirroring ``VMDetailView``'s hero:
/// the pane and its metadata chips are content, so they sit on
/// `.regularMaterial` with the shared Apparition ground wash
/// (``ApparitionPaneBackground``) — never on Liquid Glass, per
/// the HIG's "don't use Liquid Glass in the content layer."
/// The image-kind tint (IPSW = Apple blue, ISO = Tux gold,
/// OCI = purple) carries semantic weight in exactly three
/// places: the eyebrow text, the medallion's color fill, and a
/// 6% wash over the pane. Glass appears only where controls
/// live — the action bar, whose single `glassProminent` button
/// inherits the ember app accent.
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
        VStack(spacing: 24) {
            iconMedallion
            titleBlock
            metadataRow
            actionBar
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 32)
        .frame(maxWidth: 640)
        .background { ApparitionPaneBackground(cornerRadius: 24, tint: tintColor) }
        .frame(maxWidth: .infinity)
    }

    /// Circular medallion around the SF Symbol. A plain
    /// color-gradient fill (`Color.gradient` — "the standard
    /// gradient for the color") in the hero's kind tint: the
    /// medallion is content-layer imagery, so it gets a color
    /// fill, not Liquid Glass. The saturated disc is where the
    /// kind color speaks loudest; the pane wash and eyebrow only
    /// echo it.
    private var iconMedallion: some View {
        Image(systemName: iconName)
            .font(.system(size: 56, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .background(tintColor.gradient, in: .circle)
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(image.name)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text(sourceKindLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tintColor)
                .textCase(.uppercase)
                .tracking(1.2)
        }
    }

    /// Two material chips: source detail + size — the exact
    /// counterpart of ``VMDetailView``'s spec chips (metadata is
    /// content, so `.regularMaterial` capsules, not glass).
    /// Truncates the source detail in the middle so long IPSW
    /// hashes don't dominate the hero — Apple's `.middle`
    /// truncation mode preserves both ends (build + extension).
    private var metadataRow: some View {
        HStack(spacing: 12) {
            metadataChip(
                systemImage: sourceIcon,
                text: sourceDetailLabel,
                truncation: .middle
            )
            if let bytes = image.sizeInBytes {
                metadataChip(
                    systemImage: "internaldrive",
                    text: ByteCountFormatter.string(
                        fromByteCount: Int64(bytes),
                        countStyle: .file
                    ),
                    truncation: .tail
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func metadataChip(
        systemImage: String,
        text: String,
        truncation: Text.TruncationMode
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(truncation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
    }

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
                    Label("Create VM from image", systemImage: "plus.square.on.square")
                        .padding(.horizontal, 8)
                }
                .glassProminentButton()
                .controlSize(.large)

                Button(role: .destructive) {
                    try? appState.imageLibrary.remove(id: image.id)
                } label: {
                    Label("Delete", systemImage: "trash")
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

    /// The large white glyph inside the medallion. `applelogo`
    /// for macOS IPSWs (unambiguous Apple-provenance cue);
    /// `opticaldisc.fill` for Linux ISOs (thematic — ISO is
    /// literally a disc image); `cube.transparent` for OCI
    /// references (container ecosystem iconography).
    private var iconName: String {
        switch kind {
        case .macOS: "applelogo"
        case .linux: "opticaldisc.fill"
        case .oci: "cube.transparent"
        }
    }

    /// Small SF Symbol in the source-detail chip.
    private var sourceIcon: String {
        switch kind {
        case .macOS: "doc.zipper"
        case .linux: "opticaldisc"
        case .oci: "shippingbox"
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
    ///   Matches Apple's own marketing + the `applelogo`
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

/// Sidebar row for one VM — name, specs, running dot.
///
/// `name` is the `vms` dictionary key (the bundle's UUID string),
/// not a label — it's only used to look up the bundle and to
/// drive lifecycle actions. Everything actually rendered comes
/// from ``VirtualMachineBundle/displayName``.
struct VMRow: View {

    let name: String
    @Environment(AppState.self) private var appState

    private var bundle: VirtualMachineBundle? { appState.vms[name] }
    private var isRunning: Bool { appState.isRunning(name) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(isRunning ? Apparition.vital : .secondary.opacity(0.3))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(bundle?.displayName ?? name).font(.body)
                if let bundle {
                    Text("\(bundle.spec.cpuCount) CPU · \(bundle.spec.memorySizeInGigabytes) GB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
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
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(hasError ? .red : Apparition.lantern)
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
                Image(systemName: hasError ? "xmark.circle.fill" : "stop.circle")
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
