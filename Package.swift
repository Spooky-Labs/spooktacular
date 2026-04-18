// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Spooktacular",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Umbrella — re-exports Core + Application + InfrastructureApple
        .library(name: "SpooktacularKit", targets: ["SpooktacularKit"]),
        // Granular targets for consumers that want narrow dependencies
        .library(name: "SpookCore", targets: ["SpookCore"]),
        .library(name: "SpookApplication", targets: ["SpookApplication"]),
        .library(name: "SpookInfrastructureApple", targets: ["SpookInfrastructureApple"]),
        // Executables
        .executable(name: "spook", targets: ["spook"]),
        .executable(name: "Spooktacular", targets: ["Spooktacular"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-docc-plugin",
            from: "1.4.0"
        ),
    ],
    targets: [
        // ──────────────────────────────────────────────
        // Domain layer — Foundation only. No frameworks.
        // ──────────────────────────────────────────────
        .target(
            name: "SpookCore",
            path: "Sources/SpookCore"
        ),

        // ──────────────────────────────────────────────
        // Application layer — use cases and orchestration.
        // Depends on SpookCore only.
        // ──────────────────────────────────────────────
        .target(
            name: "SpookApplication",
            dependencies: ["SpookCore"],
            path: "Sources/SpookApplication"
        ),

        // ──────────────────────────────────────────────
        // Infrastructure — Apple framework adapters.
        // Virtualization, Network, Security, CryptoKit, os.
        // ──────────────────────────────────────────────
        .target(
            name: "SpookInfrastructureApple",
            dependencies: [
                "SpookCore",
                "SpookApplication",
            ],
            path: "Sources/SpookInfrastructureApple"
        ),

        // ──────────────────────────────────────────────
        // Umbrella — re-exports all layers for backward
        // compatibility. Existing `import SpooktacularKit`
        // continues to work. New code should import the
        // specific target it needs.
        // ──────────────────────────────────────────────
        .target(
            name: "SpooktacularKit",
            dependencies: ["SpookCore", "SpookApplication", "SpookInfrastructureApple"],
            path: "Sources/SpooktacularKit"
        ),

        // ──────────────────────────────────────────────
        // Executables — thin composition roots.
        // ──────────────────────────────────────────────
        .executableTarget(
            name: "spook",
            dependencies: [
                "SpooktacularKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/spook"
        ),
        .executableTarget(
            name: "Spooktacular",
            dependencies: ["SpooktacularKit"],
            path: "Sources/Spooktacular"
        ),
        .executableTarget(
            name: "spooktacular-agent",
            dependencies: ["SpookCore", "SpookApplication"],
            path: "Sources/spooktacular-agent"
        ),
        .executableTarget(
            name: "spook-controller",
            dependencies: ["SpooktacularKit"],
            path: "Sources/spook-controller"
        ),

        // ──────────────────────────────────────────────
        // Examples — minimum-viable embedding programs that
        // demonstrate the library API. Engineers reading the
        // project as a reference start here.
        // ──────────────────────────────────────────────
        .executableTarget(
            name: "VMLifecycle",
            dependencies: ["SpookCore", "SpookApplication", "SpookInfrastructureApple"],
            path: "Examples/VMLifecycle"
        ),
        .executableTarget(
            name: "GuestAgentRPC",
            dependencies: ["SpookCore", "SpookInfrastructureApple"],
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
