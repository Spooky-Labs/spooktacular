// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Spooktacular",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "SpooktacularKit", targets: ["SpooktacularKit"]),
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
        .target(
            name: "SpooktacularKit",
            path: "Sources/SpooktacularKit"
        ),
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
            name: "spook-agent",
            path: "Sources/spook-agent"
        ),
        .executableTarget(
            name: "spook-controller",
            dependencies: [],
            path: "Sources/spook-controller"
        ),
        .testTarget(
            name: "SpooktacularKitTests",
            dependencies: ["SpooktacularKit"],
            path: "Tests/SpooktacularKitTests"
        ),
    ]
)
