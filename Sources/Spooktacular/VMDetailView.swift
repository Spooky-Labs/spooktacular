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

    private var isRunning: Bool { appState.isRunning(name) }

    @State private var stats = WorkspaceStatsModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                heroPane
                if isRunning { statsPane }
            }
            .frame(maxWidth: 560)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .task(id: "\(name)-\(isRunning)") {
            // Route stats through the Apple-native
            // `VZVirtioSocketListener` the VM exposes via
            // `agentEventListener()`. The RPC client stays
            // wired for host-observable probes (latency, port
            // count).
            if isRunning,
               let client = appState.agentClients[name],
               let listener = appState.runningVMs[name]?.agentEventListener() {
                stats.start(listener: listener, client: client)
            } else {
                stats.stop()
            }
        }
    }

    // MARK: - Hero card
    //
    // One rounded-rect glass surface with a subtle state-tinted
    // gradient wash. Inside, a top-to-bottom stack:
    //
    //   1. Icon medallion (WorkspaceIconView over a glowing
    //      tinted shadow — keeps the user's custom icon front
    //      and center, adds state meaning around it).
    //   2. Title + uppercased state eyebrow.
    //   3. Spec chips (CPU / RAM / Disk / guest OS) — individual
    //      glass capsules with SF-Symbol leading glyphs, grouped
    //      in a GlassEffectContainer so they render as one
    //      blend-aware material pane.
    //   4. Status pill (Running / Suspended / Stopped).
    //   5. Action bar — already-existing glass-container layout.
    //
    // The whole pane follows the same aesthetic as
    // `ImageDetailView.heroCard`, so the library feels
    // coherent across selection types (VM vs Image).

    private var heroPane: some View {
        VStack(spacing: 24) {
            iconMedallion
            titleBlock
            specChips
            statusPill
            actionBar
        }
        .padding(.vertical, 40)
        .padding(.horizontal, 32)
        .frame(maxWidth: 640)
        .background(heroBackground)
        .clipShape(.rect(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(stateTint.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    /// Full-bleed gradient pane behind the hero content. The
    /// top-left/bottom-right axis gives the card a light source,
    /// the tint is state-driven (green running, orange suspended,
    /// neutral gray stopped) so the card's color alone signals
    /// lifecycle at a glance.
    private var heroBackground: some View {
        LinearGradient(
            colors: [
                stateTint.opacity(0.28),
                stateTint.opacity(0.10),
                .black.opacity(0.05),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// The user's custom `WorkspaceIconView` sitting over a
    /// tinted blur halo. Landmarks uses the same "hero image +
    /// radial glow" shape for landmark badges — it draws the
    /// eye to the subject while the color ring carries the
    /// state signal.
    private var iconMedallion: some View {
        WorkspaceIconView(
            spec: bundle.metadata.iconSpec ?? .defaultSpec,
            size: 140
        )
        .shadow(color: stateTint.opacity(0.45), radius: 36, y: 12)
        .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(name)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)
            Text(guestOSLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(stateTint)
                .textCase(.uppercase)
                .tracking(1.2)
        }
    }

    /// CPU / RAM / Disk spec chips — three glass capsules
    /// wrapped in a `GlassEffectContainer` so they render as
    /// one batched material surface and can morph on hover.
    /// Each chip carries a category-specific SF Symbol so the
    /// scanning eye reads the numbers + their meaning
    /// simultaneously.
    private var specChips: some View {
        GlassEffectContainer(spacing: 12) {
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
        .glassEffect(.regular, in: .capsule)
    }

    private var actionBar: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    openWindow(id: "workspace", value: name)
                } label: {
                    Label("Open Workspace", systemImage: "macwindow")
                        .padding(.horizontal, 8)
                }
                .glassProminentButton()
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])

                let transitioning = appState.transitioningVMs.contains(name)
                let suspended = !isRunning && appState.isSuspended(name)
                if isRunning {
                    Button {
                        Task { await appState.suspendVM(name) }
                    } label: {
                        if transitioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Suspend", systemImage: "pause.fill")
                        }
                    }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(transitioning)
                    .help("Save VM state and quit. Next start picks up exactly where you left off.")

                    Button {
                        Task { await appState.stopVM(name) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .glassButton()
                    .controlSize(.large)
                    .disabled(transitioning)
                } else {
                    Button {
                        Task { await appState.startVM(name) }
                    } label: {
                        if transitioning {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(
                                suspended ? "Resume" : "Start",
                                systemImage: suspended ? "play.rectangle.fill" : "play.fill"
                            )
                        }
                    }
                    .glassButton()
                    .controlSize(.large)
                    .tint(.green)
                    .disabled(transitioning)
                    .help(suspended
                        ? "Restore from the saved state and continue."
                        : "Cold-boot the VM.")

                    if bundle.spec.guestOS == .macOS {
                        Button {
                            appState.installGuestAgent(name)
                        } label: {
                            if transitioning {
                                ProgressView().controlSize(.small)
                            } else {
                                Label("Install Agent", systemImage: "arrow.down.circle")
                            }
                        }
                        .glassButton()
                        .controlSize(.large)
                        .disabled(transitioning)
                        .help("Disk-inject the guest agent so the live-metrics chart will populate on next start. Idempotent — safe to click multiple times.")
                    }
                }
            }
        }
    }

    /// Tinted Liquid Glass pill showing the current lifecycle
    /// state. Only the leading glyph carries the bright semantic
    /// color; text stays neutral against the tinted glass
    /// background, per Apple's HIG "color carries meaning once"
    /// pattern.
    @ViewBuilder
    private var statusPill: some View {
        if isRunning {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
                Text("Running")
                    .font(.caption.weight(.semibold))
            }
            .glassStatusPill()
        } else if appState.isSuspended(name) {
            HStack(spacing: 6) {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Suspended")
                    .font(.caption.weight(.semibold))
            }
            .glassStatusPill()
        } else {
            HStack(spacing: 6) {
                Image(systemName: "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text("Stopped")
                    .font(.caption.weight(.semibold))
            }
            .glassStatusPill()
        }
    }

    // MARK: - Derived state

    /// State-driven tint for the hero card. Green for running
    /// (matches the macOS system green used in menu-bar indicators
    /// for live services), orange for suspended (matches the
    /// pause-state convention), gray for stopped (neutral — no
    /// alarm, just "not running").
    private var stateTint: Color {
        if isRunning { return .green }
        if appState.isSuspended(name) { return .orange }
        return Color(white: 0.5)
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

/// `NSViewRepresentable` wrapping a **pre-created**
/// `VZVirtualMachineView` so a running VM's framebuffer hosts
/// inside a SwiftUI view without the start-before-attach race.
///
/// The view itself is owned by `AppState.graphicsViews[name]`,
/// created + wired to the VM in `AppState.startVM` **before**
/// `vm.startOrResume()` is called. Apple's VZ framework
/// subscribes the guest's graphics device when
/// `view.virtualMachine` is set; if the view doesn't exist at
/// boot time, initial framebuffer commands are buffered and
/// don't reliably flush on a late attach — the "blank
/// workspace" the user kept seeing.
///
/// `makeNSView` just hands back the pre-existing view. If it's
/// unexpectedly missing (e.g., the VM state desynced), we fall
/// back to creating a fresh one — better than crashing, though
/// the late-attach race can re-appear in that path.
struct VMDisplayView: NSViewRepresentable {

    let name: String
    let virtualMachine: VirtualMachine

    @Environment(AppState.self) private var appState

    func makeNSView(context: Context) -> VZVirtualMachineView {
        if let cached = appState.graphicsViews[name] {
            return cached
        }
        // Fallback: state was stripped (VM deleted? remote
        // mutation?). Re-create to avoid crashing, but log so
        // the missing-cache case is visible during dev.
        let view = VZVirtualMachineView()
        view.virtualMachine = virtualMachine.vzVM
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.setAccessibilityLabel("Virtual machine display for \(name)")
        view.setAccessibilityRole(.group)
        return view
    }

    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        // Pre-created view's virtualMachine pointer never
        // changes in practice — the VM instance is stable for
        // the lifetime of a running VM. Guard-and-reassign is a
        // belt-and-suspenders no-op in the common path and the
        // right fix if someone ever swaps the VM under us.
        if nsView.virtualMachine !== virtualMachine.vzVM {
            nsView.virtualMachine = virtualMachine.vzVM
        }
    }
}

/// Detail view for a selected image in the Images section.
///
/// Styled as a gradient "hero card" — full-width background
/// wash, layered glass surfaces for the icon and metadata,
/// tinted stroke, the whole thing sitting in a rounded-rect
/// glass pane. Matches the Liquid Glass data-rich UI pattern
/// Apple showcases in the "Landmarks" sample: one prominent
/// hero region per detail view, tint color carrying semantic
/// weight (IPSW = orange, OCI = blue), supplemental
/// metadata in glass chip capsules below the title.
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
        .background(heroBackground)
        .clipShape(.rect(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(tintColor.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: .infinity)
    }

    /// Full-bleed gradient pane behind the hero content. Uses
    /// the source-specific tint so IPSW + OCI images are
    /// visually distinguishable at a glance.
    private var heroBackground: some View {
        LinearGradient(
            colors: [
                tintColor.opacity(0.30),
                tintColor.opacity(0.10),
                .black.opacity(0.05),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Circular glass medallion around the SF Symbol, tinted
    /// to match the hero. `glassEffect(.regular.tint(...)
    /// .interactive(), in: .circle)` gives the round capsule
    /// a subtle pressure/hover response per Apple's Liquid
    /// Glass interactive-variant guidance.
    private var iconMedallion: some View {
        Image(systemName: iconName)
            .font(.system(size: 56, weight: .regular))
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .glassEffect(
                .regular.tint(tintColor).interactive(),
                in: .circle
            )
            .shadow(color: tintColor.opacity(0.35), radius: 30, y: 10)
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

    /// Two glass chips: source detail + size. Truncates the
    /// source detail in the middle so long IPSW hashes don't
    /// dominate the hero — Apple's `.middle` truncation mode
    /// preserves both ends (build + extension).
    private var metadataRow: some View {
        GlassEffectContainer(spacing: 12) {
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
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(truncation)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
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
struct VMRow: View {

    let name: String
    @Environment(AppState.self) private var appState

    private var isRunning: Bool { appState.isRunning(name) }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 7))
                .foregroundStyle(isRunning ? .green : .secondary.opacity(0.3))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.body)
                if let bundle = appState.vms[name] {
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
