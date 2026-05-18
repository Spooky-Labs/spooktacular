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
        // System-extension executable (Track F''). `build-app.sh`
        // wraps the produced binary in a `.systemextension`
        // bundle and embeds it under the main app's
        // `Contents/Library/SystemExtensions/`. The main app
        // requests activation via `OSSystemExtensionRequest`.
        .executable(name: "SpooktacularNetworkFilter", targets: ["SpooktacularNetworkFilter"]),
        // Out-of-process VM lifecycle helper (Track J). A
        // crash in VZVirtualMachine inside the helper shows
        // up to the main app as a dropped XPC connection
        // rather than a crashed GUI. `build-app.sh` wraps
        // the binary in a `.xpc` bundle under
        // `Contents/XPCServices/`; `launchd` launches one
        // process per connecting parent and reaps it when
        // the parent exits.
        .executable(name: "SpooktacularVMHelper", targets: ["SpooktacularVMHelper"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
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
            dependencies: ["SpooktacularKit"],
            path: "Sources/Spooktacular"
        ),
        // System-extension host for the NEFilterDataProvider
        // subclass (Track F''). This executable is packaged
        // as a `.systemextension` by `build-app.sh` and
        // activated via `OSSystemExtensionRequest`. The
        // `SpooktacularInfrastructureApple` dependency is
        // required so the linker pulls
        // `SpooktacularNetworkFilterProvider` (the NE principal
        // class referenced by Info.plist) into the binary.
        .executableTarget(
            name: "SpooktacularNetworkFilter",
            dependencies: ["SpooktacularInfrastructureApple"],
            path: "Sources/SpooktacularNetworkFilter"
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
        .executableTarget(
            name: "spooktacular-agent",
            dependencies: ["SpooktacularCore", "SpooktacularApplication"],
            path: "Sources/spooktacular-agent"
        ),
        .executableTarget(
            name: "spooktacular-controller",
            dependencies: ["SpooktacularKit"],
            path: "Sources/spooktacular-controller"
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
        .executableTarget(
            name: "GuestAgentRPC",
            dependencies: ["SpooktacularCore", "SpooktacularInfrastructureApple"],
            path: "Examples/GuestAgentRPC"
        ),

        // ──────────────────────────────────────────────
        // Tests
        // ──────────────────────────────────────────────
        .testTarget(
            name: "SpooktacularKitTests",
            dependencies: ["SpooktacularKit"],
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
