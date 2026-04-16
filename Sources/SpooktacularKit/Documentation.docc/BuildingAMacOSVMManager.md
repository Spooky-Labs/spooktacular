# Building a macOS VM Manager

Compose the Spooktacular libraries into a first-class Mac app.

## Overview

This article walks through the layered structure of the
Spooktacular SwiftUI app so you can build something comparable
without repeating the architectural decisions we already settled.

The app target depends on three Swift packages in this repo:

- **`SpookCore`** — pure Swift domain types. No AppKit, no
  `Virtualization`, no networking. Use it for models, enums,
  and protocol "ports" that describe what the app needs without
  committing to a concrete transport.
- **`SpookApplication`** — use cases and services that combine
  domain types into workflows (RBAC evaluation, tenant
  isolation, runner-pool orchestration).
- **`SpookInfrastructureApple`** — Apple-framework adapters.
  Wraps `VZVirtualMachine`, `NSPasteboard`, `NSWorkspace`,
  `Security.framework`, `Network.framework`, `Foundation Models`.

Views stay thin: they observe `@Observable` state objects and
call through to these libraries. Keeping logic out of views is
what makes the same codebase ship a CLI, a Kubernetes
controller, and an App Store binary from one package.

## Topics

### Scene architecture

Spooktacular uses a multi-window scene graph. Each running VM
opens in its own `WindowGroup` scene keyed by VM name, so users
can close the library and keep workspaces open — the same
pattern GhostVM pioneered. The library itself is a separate
`WindowGroup(id: "library")`; Settings stays in its own `Scene`.

Open a workspace from any view:

```swift
@Environment(\.openWindow) private var openWindow

Button("Open Workspace") {
    openWindow(id: "workspace", value: vmName)
}
```

Track which workspaces are currently visible on `AppState` so
the Dock tile coordinator and menu-bar popover can react.

### Liquid Glass everywhere

All app chrome — toolbars, sheets, popovers, inspector drawers,
the command palette — uses `.glassEffect` (macOS 26+) with
`GlassEffectContainer` grouping where multiple glass elements
share a visual region. `GlassModifiers.swift` wraps the API
calls with `#if compiler(>=6.2)` + `#available(macOS 26.0, *)`
so one source tree compiles against older SDKs with a
`.ultraThinMaterial` fallback.

The only opaque surface is the `VZVirtualMachineView`
framebuffer inside `WorkspaceWindow`.

### Per-workspace icons

`IconSpec` (in `SpookCore`) is a `Codable`, `Sendable`,
`Hashable` enum with four modes:

- `.cloneApp(bundleID:)` — borrow an installed app's icon
- `.stack(top:bottom:)` — overlay two SF Symbols
- `.glassFrame(symbol:tint:)` — Liquid-Glass rounded
  squircle with a tinted SF Symbol
- `.preset(name:)` — bundled PNG

`WorkspaceIconRenderer` (in `SpookInfrastructureApple`) is the
only place that bridges the domain spec to `NSImage`. Views
upstream consume a ready-to-use image; the renderer is
`@MainActor`-isolated because AppKit demands it.

### App Intents and Siri

The `VMIntents.swift` file registers six intents (start, stop,
snapshot, restore, clone, run-command) with `VMQuery`
supplying parameter auto-completion. `SpooktacularShortcuts` as
an `AppShortcutsProvider` registers natural-language phrases so
"Hey Siri, start runner-01 in Spooktacular" works after first
launch.

Intents go through `IntentAppState`, which reads VM bundles
from disk on each invocation — no dependency on a running
instance of the app. That's what makes the intents usable from
Shortcuts triggered by Focus filters or Spotlight when the app
isn't foregrounded.

### Foundation Models (WWDC 2025)

`ErrorExplainer` uses `SystemLanguageModel.default` to stream
an on-device natural-language explanation of any VM error.
Shown as a glass sheet on the error alert. No network call, no
API keys, no secrets leave the host.

The feature is gated behind `#if canImport(FoundationModels)`
and `@available(macOS 26.0, *)`. On hosts without Apple
Intelligence the view degrades to a static explanation +
copy-error-to-clipboard.

### Host integration

Four channels turn a running VM into a proper desktop citizen:

- **Clipboard** — `ClipboardBridge` observes
  `NSPasteboard.changeCount` at 500 ms and prompts per-copy
  for sync permission (glass sheet, 15-minute approval cache).
- **Ports** — `PortForwardingMonitor` polls
  `GuestAgentClient.listeningPorts()` every 5 s. Surface them
  in a toolbar popover with "open in browser" / "copy URL".
- **Snapshots** — `SnapshotInspector` is pure UI over
  `SnapshotManager.save/restore/list/delete`.
- **Hardware** — `HardwareEditor` retunes CPU/RAM/disk via
  `VirtualMachineBundle.writeSpec` on a stopped VM.

### Notifications

`VMNotifications` posts `UNUserNotificationCenter` toasts on
start / stop / fail, with `timeSensitive` interruption level
for failures so they reach the user even in Focus modes.
Authorization is requested lazily on first post so launch
doesn't trigger a permission dialog.

### Command palette

`CommandPalette` (⌘K) is a glass sheet listing every lifecycle
operation scoped to the known VMs. Fuzzy substring match on
title + subtitle. Enter runs the top match; Esc dismisses.

### Charts

`WorkspaceStatsSidebar` uses Swift Charts (system framework,
no dependency) to plot a 60-second rolling window of agent
round-trip latency and listening-port count. Pollers bind to
the guest agent via the existing `GuestAgentClient`.

## See Also

- ``IconSpec``
- ``VirtualMachineBundle``
- ``VirtualMachine``
- ``GuestAgentClient``
- ``SnapshotManager``
- <doc:Provisioning>
- <doc:GettingStarted>
