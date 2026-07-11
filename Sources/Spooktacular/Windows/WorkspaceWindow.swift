import AppKit
import SwiftUI
@preconcurrency import Virtualization
import SpooktacularInfrastructureApple
import SpooktacularKit

/// A window dedicated to a single VM workspace.
///
/// Each running VM gets its own `WorkspaceWindow` — separate from
/// the library window — so users can close the library and keep
/// their workspaces open, matching the "VMs-are-apps" mental model
/// pioneered by GhostVM. The window hosts a live
/// ``VZVirtualMachineView`` plus a Liquid-Glass toolbar and
/// receives focus-change callbacks that drive the Dock tile
/// coordinator.
///
/// The window is opened via
/// `openWindow(id: "workspace", value: vmName)` from any other
/// scene. SwiftUI handles window uniqueness by value — requesting
/// the same VM name twice brings the existing window forward
/// instead of creating a duplicate.
struct WorkspaceWindow: View {

    /// The VM this window represents, passed as the window's
    /// presented value. Keyed by name (the library's identifier).
    let vmName: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSnapshots: Bool = false
    @State private var showHardware: Bool = false

    /// Holds the most-recently-resolved IP for two seconds so the
    /// toolbar "Copy IP" button can briefly flip to a checkmark
    /// after a successful copy — then reverts to the default
    /// label. A plain `@State Bool` wouldn't distinguish "just
    /// copied 10.1.2.3" from "just copied 10.1.2.4", which
    /// matters when the user re-resolves and the VM's DHCP
    /// lease has rotated.
    @State private var lastCopiedIP: String?

    var body: some View {
        Group {
            if let bundle = appState.vms[vmName] {
                content(for: bundle)
            } else {
                missingWorkspace
            }
        }
        // Animates exactly one thing: the séance ⇄ guest-display
        // swap, bound to the "is this VM running?" state change.
        // Under Reduce Motion the transitions degrade to plain
        // crossfades, so the quick non-bouncy curve fits better
        // than the signature spring.
        //
        // `animation(_:value:)` docs:
        // https://developer.apple.com/documentation/SwiftUI/View/animation(_:value:)
        .animation(
            reduceMotion ? Apparition.quick : Apparition.spring,
            value: appState.runningVMs[vmName] != nil
        )
        .frame(minWidth: 720, minHeight: 460)
        .navigationTitle(appState.vms[vmName]?.displayName ?? vmName)
        .task(id: vmName) {
            await appState.workspaceDidOpen(vmName)
        }
        .onDisappear {
            appState.workspaceDidClose(vmName)
        }
        .sheet(isPresented: $showSnapshots) {
            SnapshotInspector(vmName: vmName)
                .environment(appState)
        }
        .sheet(isPresented: $showHardware) {
            HardwareEditor(vmName: vmName)
                .environment(appState)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(for bundle: VirtualMachineBundle) -> some View {
        if let vm = appState.runningVMs[vmName] {
            // No `.ignoresSafeArea()` here — the previous
            // revision let the VZVirtualMachineView extend under
            // the window's title bar + toolbar, which clipped
            // the top row of the guest's menu bar and display
            // pixels on every workspace window. Apple's safe
            // area on macOS is exactly the window's content
            // inset region; honouring it keeps the guest
            // display below the chrome.
            //
            // Docs: https://developer.apple.com/documentation/swiftui/view/ignoressafearea(_:edges:)
            VMDisplayView(
                name: vmName,
                virtualMachine: vm,
                // Pass the pre-created NSView explicitly. Reading
                // from `@Environment(AppState.self)` inside
                // `NSViewRepresentable.makeNSView` has been
                // unreliable — Environment hydration can return
                // a fresh instance whose dict is empty, silently
                // falling through to the late-attach fallback.
                // Resolving `appState` here (where Environment
                // injection is reliable) and passing the value
                // down sidesteps the whole class of issue.
                cachedView: appState.graphicsViews[vmName]
            )
            .toolbar { runningToolbar }
            // The guest materializes. Deliberately NOT
            // `.blurReplace` on this branch: SwiftUI filter
            // effects like blur don't reach into AppKit-hosted
            // content, so on an `NSViewRepresentable` the blur
            // half of that transition would silently no-op.
            // Opacity + a whisper of scale are the effects that
            // demonstrably apply to hosted views, and the swap's
            // spring lives on the container's
            // `animation(_:value:)` above.
            .transition(guestMaterialize)
        } else {
            WorkspaceLaunchView(name: vmName, bundle: bundle)
                .toolbar { stoppedToolbar }
                // Pure SwiftUI content, so the full blur+scale
                // materialize applies. When Reduce Motion is on
                // the system swaps this for a plain crossfade —
                // motion transitions carry `hasMotion`, and "that
                // transition will be replaced by opacity when
                // Reduce Motion is enabled":
                // https://developer.apple.com/documentation/SwiftUI/TransitionProperties/hasMotion
                //
                // `blurReplace` docs:
                // https://developer.apple.com/documentation/SwiftUI/Transition/blurReplace
                .transition(.blurReplace)
        }
    }

    /// The guest display's materialize/dissipate transition:
    /// opacity with a 2% scale settle. Reduce Motion drops the
    /// scale and leaves a plain crossfade (hand-gated here because
    /// the automatic `hasMotion` → opacity replacement is a
    /// `Transition`-protocol behavior, and this branch uses the
    /// type-erased `AnyTransition` combinators:
    /// <https://developer.apple.com/documentation/SwiftUI/AnyTransition/combined(with:)>).
    private var guestMaterialize: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.98))
    }

    @ViewBuilder
    private var missingWorkspace: some View {
        ContentUnavailableView(
            "Workspace Unavailable",
            systemImage: "questionmark.folder",
            description: Text("The VM was removed or is not loaded.")
        )
        .padding()
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var runningToolbar: some ToolbarContent {
        // Clipboard-bridge health — a status indicator, not an action.
        // `.sharedBackgroundVisibility(.hidden)` keeps it in its own
        // grouping so it doesn't glass-merge with the action buttons.
        // The system applies Liquid Glass to toolbar items automatically;
        // we never hand-roll `.glassButton()`/`.glassEffect` here — doing
        // so double-stacked the material and broke the buttons' look.
        ToolbarItem(placement: .primaryAction) {
            ClipboardStatusPill(
                snapshot: appState.clipboardStatuses[vmName]
                    ?? .init(state: .notStarted)
            )
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.fixed)

        // Lifecycle cluster: Suspend / Stop share one glass group.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await appState.suspendVM(vmName) }
            } label: {
                Label("Suspend", systemImage: "pause.fill")
                    // Hover delight: one-shot symbol bounce on pointer
                    // entry (Reduce-Motion-gated inside the modifier).
                    // Attached to the Label so only the symbol animates.
                    .hoverSymbolBounce()
            }
            .help("Save VM state and quit — next start picks up where you left off")

            Button {
                Task { await appState.stopVM(vmName) }
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .hoverSymbolBounce()
            }
            .help("Stop this workspace")
            .accessibilityIdentifier(AccessibilityID.stopButton)
        }

        ToolbarSpacer(.fixed)

        // Utilities cluster: Snapshots + the network split-button.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showSnapshots = true
            } label: {
                Label("Snapshots", systemImage: "clock.arrow.circlepath")
                    .hoverSymbolBounce()
            }
            .help("Manage snapshots for this workspace (⇧⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .shift])

            // Network actions under a split-button Menu: primary tap
            // copies the IP; the chevron exposes `SSH in Terminal…`.
            // Docs: https://developer.apple.com/documentation/swiftui/menu
            Menu {
                Button {
                    Task { await launchSSH() }
                } label: {
                    Label("SSH in Terminal…", systemImage: "terminal")
                }
                .help("Resolve the workspace's IP and open an ssh session in Terminal.app.")
            } label: {
                Label(
                    lastCopiedIP ?? "Copy IP",
                    systemImage: lastCopiedIP != nil ? "checkmark.circle.fill" : "number"
                )
                // Morph number → checkmark on copy + a one-shot bounce so
                // the copy registers without a modal toast.
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: lastCopiedIP)
                // Hover bounce composes with the copy-confirmation
                // bounce above — discrete symbol effects keyed to
                // different values stack independently.
                .hoverSymbolBounce()
            } primaryAction: {
                Task { await resolveAndCopyIP() }
            }
            .help("Resolve this workspace's IPv4 address. Tap to copy it; chevron for other network actions.")
            .accessibilityLabel(
                lastCopiedIP.map { "Copied \($0)" } ?? "Workspace network actions"
            )
            .animation(.smooth(duration: 0.2), value: lastCopiedIP)
        }
    }

    /// Resolves the running VM's IPv4 address from its MAC via
    /// `IPResolver` (DHCP lease table + ARP fallback — same path
    /// as `spook ip <vm>`) and copies the result to the general
    /// pasteboard.
    ///
    /// Intentionally idempotent: a second tap re-resolves in case
    /// the guest's DHCP lease has rotated since the last call.
    /// The toolbar label flips to a checkmark for two seconds so
    /// the user sees confirmation without a modal toast.
    ///
    /// `NSPasteboard.general` docs:
    /// https://developer.apple.com/documentation/appkit/nspasteboard/general
    private func resolveAndCopyIP() async {
        guard let mac = appState.vms[vmName]?.spec.macAddress else { return }
        do {
            guard let ip = try await IPResolver.resolveIP(macAddress: mac) else {
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(ip, forType: .string)
            lastCopiedIP = ip
            // Revert the label after a brief confirmation window.
            // Checking `lastCopiedIP == ip` means a later copy
            // with a different IP (rotated DHCP lease) doesn't
            // accidentally erase its own confirmation.
            try? await Task.sleep(for: .seconds(2))
            if lastCopiedIP == ip { lastCopiedIP = nil }
        } catch {
            // Resolution failure is silent — the button simply
            // doesn't flip to the checkmark, and the user can
            // try again. Surfacing an error toast here would be
            // noisier than useful (DHCP + ARP both fail within
            // the first ~15s of a cold boot).
            Log.vm.debug("IP resolution failed for \(vmName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolves the running VM's IPv4 address and opens the host's
    /// default ssh:// handler — mirrors `spook ssh <vm>` for users
    /// who live in the GUI. Terminal.app registers itself as the
    /// default handler on stock macOS, but iTerm2/Warp/etc. all
    /// register too, so this honours the user's chosen terminal.
    ///
    /// Uses defaults of `admin` + `~/.ssh/id_*` — the same as
    /// `spook ssh`. For non-default users or explicit key paths,
    /// the CLI's `--user` and `--key` flags remain the escape
    /// hatch; adding fields to a toolbar popover would bloat the
    /// 95%-case one-tap flow.
    ///
    /// `NSWorkspace.open(_:)` docs:
    /// https://developer.apple.com/documentation/appkit/nsworkspace/open(_:)
    private func launchSSH() async {
        guard let mac = appState.vms[vmName]?.spec.macAddress else { return }
        do {
            guard let ip = try await IPResolver.resolveIP(macAddress: mac),
                  let url = URL(string: "ssh://admin@\(ip)") else {
                return
            }
            // `open(_:)` returns false only when no handler is
            // registered for the URL scheme, which on macOS is
            // effectively never for `ssh://`. We log the edge
            // case for support diagnostics rather than surfacing
            // a toast.
            if !NSWorkspace.shared.open(url) {
                Log.vm.debug("No handler registered for ssh:// scheme on this host.")
            }
        } catch {
            Log.vm.debug("SSH launch failed for \(vmName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    @ToolbarContentBuilder
    private var stoppedToolbar: some ToolbarContent {
        // Start split-button: primary tap boots normally; the chevron
        // exposes Recovery-mode boot
        // (`VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery`).
        // Its own group + green tint mark it as the primary action. The
        // system applies Liquid Glass automatically — no hand-rolled glass.
        // Docs: https://developer.apple.com/documentation/swiftui/menu
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button {
                    Task { await appState.startVM(vmName, recovery: true) }
                } label: {
                    Label("Start in Recovery Mode", systemImage: "wrench.and.screwdriver")
                }
                .help("Boot into macOS Recovery (Disk Utility, Startup Security Utility, reinstall).")
            } label: {
                Label("Start", systemImage: "play.fill")
                    // Hover delight: one-shot symbol bounce on pointer
                    // entry (Reduce-Motion-gated inside the modifier).
                    .hoverSymbolBounce()
            } primaryAction: {
                Task { await appState.startVM(vmName) }
            }
            .tint(.green)
            .help("Start this workspace. Hold the chevron for Recovery-mode boot.")
            .accessibilityIdentifier(AccessibilityID.startButton)
        }

        ToolbarSpacer(.fixed)

        // Utilities cluster: Hardware + Snapshots.
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                showHardware = true
            } label: {
                Label("Hardware", systemImage: "cpu")
                    .hoverSymbolBounce()
            }
            .help("Edit CPU, memory, and disk (⇧⌘H)")
            .keyboardShortcut("h", modifiers: [.command, .shift])

            Button {
                showSnapshots = true
            } label: {
                Label("Snapshots", systemImage: "clock.arrow.circlepath")
                    .hoverSymbolBounce()
            }
            .help("Manage snapshots for this workspace (⇧⌘S)")
            .keyboardShortcut("s", modifiers: [.command, .shift])
        }
    }
}

// MARK: - Launch view

/// The séance — the workspace's stopped-state landing.
///
/// Shown when the user opens a workspace window for a stopped VM.
/// The night-ground aurora washes the content layer, and the
/// séance itself is a single floating Liquid Glass hero pane over
/// that ambience — `glassEffect(.regular)` in a 28pt continuous
/// rounded rect, the pane also declared as the concentric-corner
/// container via `containerShape(.rect(cornerRadius: 28))` so any
/// nested rounded element resolves its corners against the pane's
/// geometry (macOS 27 concentric-corner contract). Inside the
/// pane, the workspace icon *materializes* with a one-shot
/// entrance, the spec line speaks in monospaced machine-voice,
/// and the wisp `glassProminent` Start button is the surface's
/// single prominent action.
///
/// ## Motion contract
/// The entrance is a one-shot staggered reveal bound to the view's
/// insertion (`onAppear` flips ``materialized`` exactly once per
/// appearance — nothing loops). Under Reduce Motion, ``revealed``
/// is `true` from the first frame, so the state never changes and
/// no motion occurs at all; the content simply renders settled.
///
/// `accessibilityReduceMotion` docs:
/// <https://developer.apple.com/documentation/SwiftUI/EnvironmentValues/accessibilityReduceMotion>
struct WorkspaceLaunchView: View {

    let name: String
    let bundle: VirtualMachineBundle

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    /// Drives the one-shot materialize entrance. Flipped to `true`
    /// in `onAppear`, so the reveal replays each time the séance
    /// returns (fresh `@State` on every re-insertion — e.g. after
    /// the guest dissipates on stop).
    @State private var materialized = false

    /// The entrance's effective state: settled immediately when
    /// Reduce Motion is on, otherwise once `onAppear` has fired.
    private var revealed: Bool { materialized || reduceMotion }

    var body: some View {
        VStack {
            Spacer()
            seanceCard
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Night ground wash — the aurora is a content-layer tint
        // bias over the system window background, not glass. It
        // extends under the (system-glass) toolbar so the chrome
        // floats over ambience, not over a hard seam.
        .background {
            AuroraBackground()
                .ignoresSafeArea()
        }
        .onAppear { materialized = true }
    }

    /// The séance's hero pane: one Liquid Glass card floating over
    /// the aurora. `.regular` glass (not `.clear` — the aurora is a
    /// soft tint wash, not a visually rich background that would
    /// warrant clear + dimming). The 28pt continuous rounded rect
    /// is also declared as the pane's `containerShape`, making it
    /// the concentric-corner root for anything nested inside.
    ///
    /// This is the only glass shape on the surface (the toolbar is
    /// system glass in a separate layer), so there's no adjacent
    /// glass to batch — a `GlassEffectContainer` would wrap exactly
    /// one shape and is deliberately omitted.
    private var seanceCard: some View {
        VStack(spacing: 28) {
            // The apparition materializes: blur condenses, scale
            // settles, opacity arrives — one shot, bound to the
            // `revealed` state change (the view's appearance event).
            WorkspaceIconView(spec: bundle.metadata.iconSpec ?? .defaultSpec, size: 140)
                .scaleEffect(revealed ? 1 : 0.85)
                .blur(radius: revealed ? 0 : 18)
                .opacity(revealed ? 1 : 0)
                .animation(Apparition.spring, value: revealed)

            VStack(spacing: 6) {
                Text(bundle.displayName)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .foregroundStyle(Apparition.fogText)
                // Machine-voice: the spec line is something the
                // machine says, so it speaks fully monospaced
                // (inherently tabular — no `monospacedDigit()`
                // needed on top).
                Text(specSummary)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 6)
            .animation(Apparition.spring.delay(0.08), value: revealed)

            // The surface's ONE glassProminent, in wisp — the
            // primary action and the only place the accent shouts
            // (the prominent style itself carries the wisp, so no
            // manual `.tint` here).
            Button {
                Task { await appState.startVM(name) }
            } label: {
                Label("Start Workspace", systemImage: "play.fill")
                    .font(.system(.headline, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    // Hover delight: one-shot symbol bounce on
                    // pointer entry (Reduce-Motion-gated).
                    .hoverSymbolBounce()
            }
            .glassProminentButton()
            .controlSize(.large)
            .accessibilityIdentifier(AccessibilityID.startButton)
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 10)
            .animation(Apparition.spring.delay(0.16), value: revealed)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 36)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        // Concentric-corner root: nested rounded elements inside
        // this pane share corner centers with the 28pt container.
        // Docs: https://developer.apple.com/documentation/swiftui/view/containershape(_:)
        .containerShape(.rect(cornerRadius: 28))
        // The wisp halo now glows *beneath* the glass — a brand
        // moment refracted through the pane instead of a raw glow
        // spilling past the card's edges (its old home behind the
        // icon bled outside the pane bounds).
        .background { wispHalo }
        // The pane fades in with the first beat of the entrance so
        // an empty glass slab never precedes its contents. Same
        // state binding, same gate as the staggered reveal.
        .opacity(revealed ? 1 : 0)
        .animation(Apparition.spring, value: revealed)
    }

    /// A soft wisp halo beneath the séance's glass pane — the
    /// séance's cool glow.
    ///
    /// A brand moment (wisp is reserved for exactly these), drawn
    /// as a heavily blurred fill so it reads as light, not as a
    /// shape — and layered *behind* the glass so the pane refracts
    /// it. It appears once with the materialize entrance and then
    /// holds perfectly still — no looping glow. Light mode halves
    /// the strength; fog wants a hint, not a lamp.
    private var wispHalo: some View {
        Circle()
            .fill(Apparition.wisp)
            .frame(width: 240, height: 240)
            .blur(radius: 60)
            .opacity(revealed ? (colorScheme == .dark ? 0.20 : 0.10) : 0)
    }

    private var specSummary: String {
        let cpu = bundle.spec.cpuCount
        let mem = bundle.spec.memorySizeInGigabytes
        let disk = bundle.spec.diskSizeInGigabytes
        return "\(cpu) CPU · \(mem) GB RAM · \(disk) GB disk"
    }
}

// MARK: - Icon view

/// Renders an ``IconSpec`` as SwiftUI content by routing through
/// ``WorkspaceIconRenderer``. Used in the workspace launch view,
/// library cards, and the settings icon picker.
struct WorkspaceIconView: View {
    let spec: IconSpec
    let size: CGFloat

    var body: some View {
        Image(nsImage: WorkspaceIconRenderer.render(spec, size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityLabel("Workspace icon")
    }
}
