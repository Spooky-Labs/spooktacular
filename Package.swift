// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Spooktacular",
    platforms: [
        // Target macOS 26 (Tahoe). Spooktacular is a pre-1.0
        // reference architecture for Apple's Virtualization
        // framework — we hold the deployment target at the
        // current release so every new API (Liquid Glass,
        // VZLinuxRosettaDirectoryShare availability tightening,
        // save-state lifecycle) is available unconditionally.
        // Dropping `if #available(macOS 14, *)` / `@available`
        // scaffolding keeps the codebase legible and matches
        // the user's "pre-1.0, no compat hedges" direction.
        .macOS("26.0")
    ],
    products: [
        // Umbrella — re-exports Core + Application + InfrastructureApple
        .library(name: "SpooktacularKit", targets: ["SpooktacularKit"]),
        // Granular targets for consumers that want narrow dependencies
        .library(name: "SpooktacularCore", targets: ["SpooktacularCore"]),
        .library(name: "SpooktacularApplication", targets: ["SpooktacularApplication"]),
        .library(name: "SpooktacularInfrastructureApple", targets: ["SpooktacularInfrastructureApple"]),
        // Executables
        .executable(name: "spooktacular-cli", targets: ["spooktacular-cli"]),
        .executable(name: "Spooktacular", targets: ["Spooktacular"]),
        // Out-of-process VM lifecycle helper (Track J). A
        // crash in VZVirtualMachine inside the helper shows
        // up to the main app as a dropped XPC connection
        // rather than a crashed GUI. `build-app.sh` wraps
        // the binary in a `.xpc` bundle under
        // `Contents/XPCServices/`; `launchd` launches one
        // process per connecting parent and reaps it when
        // the parent exits.
        .executable(name: "SpooktacularVMHelper", targets: ["SpooktacularVMHelper"]),
        // Spooktacular Guest Tools — the in-guest companion
        // app. Ships as a sandboxed `.app` in /Applications
        // inside every Spooktacular macOS VM. Runs the SPICE
        // clipboard bridge AND (once Phase 2 lands) the
        // HTTP/vsock guest-agent API. MenuBarExtra UI so the
        // user can open/restart/quit it from the menu bar.
        .executable(name: "SpooktacularGuestTools", targets: ["SpooktacularGuestTools"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
        // Clean-room Swift implementation of the SPICE vd_agent
        // protocol. Standalone MIT-licensed package (will be
        // extracted to its own public repo post-launch — see
        // Packages/SpiceProtocol/docs/SPEC_ATTRIBUTION.md).
        .package(path: "Packages/SpiceGuestAgent"),
        // Type-safe SF Symbols. `Image(systemName: "clock.arrow.circlepth")`
        // is a silent failure — a typo'd symbol renders as a blank
        // frame with no compiler error and no runtime warning. Every
        // symbol reference in the GUI goes through this package's
        // generated properties instead, so a bad name is a build
        // error. Generated from Apple's SF Symbols 7.2 catalog;
        // MIT-licensed.
        .package(
            url: "https://github.com/WikipediaBrown/SFSymbolsKit.git",
            from: "1.0.9"
        ),
    ],
    targets: [
        // ──────────────────────────────────────────────
        // Domain layer — Foundation only. No frameworks.
        // ──────────────────────────────────────────────
        .target(
            name: "SpooktacularCore",
            path: "Sources/SpooktacularCore"
        ),

        // ──────────────────────────────────────────────
        // Application layer — use cases and orchestration.
        // Depends on SpooktacularCore only.
        // ──────────────────────────────────────────────
        .target(
            name: "SpooktacularApplication",
            dependencies: ["SpooktacularCore"],
            path: "Sources/SpooktacularApplication"
        ),

        // ──────────────────────────────────────────────
        // Infrastructure — Apple framework adapters.
        // Virtualization, Network, Security, CryptoKit, os.
        // ──────────────────────────────────────────────
        .target(
            name: "SpooktacularInfrastructureApple",
            dependencies: [
                "SpooktacularCore",
                "SpooktacularApplication",
            ],
            path: "Sources/SpooktacularInfrastructureApple"
        ),

        // ──────────────────────────────────────────────
        // Umbrella — re-exports all layers for backward
        // compatibility. Existing `import SpooktacularKit`
        // continues to work. New code should import the
        // specific target it needs.
        // ──────────────────────────────────────────────
        .target(
            name: "SpooktacularKit",
            dependencies: ["SpooktacularCore", "SpooktacularApplication", "SpooktacularInfrastructureApple"],
            path: "Sources/SpooktacularKit"
        ),

        // ──────────────────────────────────────────────
        // Executables — thin composition roots.
        // ──────────────────────────────────────────────
        .executableTarget(
            name: "spooktacular-cli",
            dependencies: [
                "SpooktacularKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/spooktacular-cli"
        ),
        .executableTarget(
            name: "Spooktacular",
            dependencies: [
                "SpooktacularKit",
                .product(name: "SFSymbolsKit", package: "SFSymbolsKit"),
            ],
            path: "Sources/Spooktacular"
        ),
        // VM lifecycle helper (Track J). Depends on
        // `SpooktacularCore` for `VMHelperProtocol` — the
        // protocol must be visible on both sides of the XPC
        // wire. Later commits add
        // `SpooktacularInfrastructureApple` here when real
        // VM ops move behind the boundary.
        .executableTarget(
            name: "SpooktacularVMHelper",
            dependencies: ["SpooktacularCore"],
            path: "Sources/SpooktacularVMHelper"
        ),
        // ──────────────────────────────────────────────
        // Spooktacular Guest Tools — the `.app` that lives
        // inside every macOS guest VM under /Applications.
        //
        // Combines:
        //   - SPICE clipboard bridge (SpiceClipboardAgent lib)
        //   - Menu-bar status + user controls (MenuBarExtra)
        //   - HTTP/vsock guest-agent API (Phase 2)
        //
        // Auto-installed by DiskInjector at VM first boot (no
        // DMG drag, no installer). Registers itself as a
        // login item on first launch via SMAppService so it
        // persists across reboots.
        //
        // Runs SANDBOXED. See SpooktacularGuestTools.entitlements
        // for the narrow entitlements it needs (virtio-serial
        // tty access via `com.apple.security.device.serial`,
        // NSPasteboard access via the stock sandbox). Does NOT
        // use AF_VSOCK — that socket family has no sandbox
        // entitlement on macOS, so the Phase-2 HTTP/vsock
        // guest-agent API was removed from this bundle. If
        // host→guest RPC returns, it'll land as a Track-J XPC
        // helper that's un-sandboxed and talks to this bundle
        // over `NSXPCConnection`.
        // ──────────────────────────────────────────────
        .executableTarget(
            name: "SpooktacularGuestTools",
            dependencies: [
                "SpooktacularCore",
                .product(
                    name: "SpiceClipboardAgent",
                    package: "SpiceGuestAgent"
                ),
            ],
            path: "Sources/SpooktacularGuestTools"
        ),
        // ──────────────────────────────────────────────
        // Examples — minimum-viable embedding programs that
        // demonstrate the library API. Engineers reading the
        // project as a reference start here.
        // ──────────────────────────────────────────────
        .executableTarget(
            name: "VMLifecycle",
            dependencies: ["SpooktacularCore", "SpooktacularApplication", "SpooktacularInfrastructureApple"],
            path: "Examples/VMLifecycle"
        ),

        // ──────────────────────────────────────────────
        // Tests
        // ──────────────────────────────────────────────
        .testTarget(
            name: "SpooktacularKitTests",
            dependencies: [
                "SpooktacularKit",
                // Pins the three AppShortcut symbol literals that
                // `_const String` forbids from being type-safe —
                // see AppShortcutSymbolTests.
                .product(name: "SFSymbolsKit", package: "SFSymbolsKit"),
            ],
            path: "Tests/SpooktacularKitTests"
        ),
        // UI tests — XCUITest-based, capture App Store
        // screenshots via `XCTAttachment` (see
        // `Tests/SpooktacularUITests/ScreenshotTests.swift`).
        //
        // Declared here so `swift build --target
        // SpooktacularUITests` catches compile regressions on
        // every PR (accessibility-identifier renames, SwiftUI
        // API changes). NOT runnable via `swift test` — Apple's
        // limit: SwiftPM can't host an XCUITest bundle with a
        // launchable app target, so `XCUIApplication().launch()`
        // aborts at runtime. Actually running these tests (and
        // producing screenshot artifacts) requires an
        // `.xcodeproj` with a dedicated "UI Testing Bundle"
        // target — tracked as a separate infrastructure task
        // (xcodegen or tuist wiring).
        .testTarget(
            name: "SpooktacularUITests",
            dependencies: ["SpooktacularKit"],
            path: "Tests/SpooktacularUITests"
        ),
    ]
)
