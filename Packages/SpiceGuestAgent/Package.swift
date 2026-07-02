// swift-tools-version: 6.2
import PackageDescription

/// # SpiceGuestAgent
///
/// Guest-side SPICE clipboard agent — a pure-logic Swift actor
/// that bridges an in-guest `NSPasteboard` to a SPICE host over
/// Apple's `VZSpiceAgentPortAttachment` virtio-serial port.
///
/// Exposes a single library product, `SpiceClipboardAgent`, so
/// higher-level guest-tools apps can own their own UI and
/// lifecycle while delegating clipboard bridging here.
///
/// The menu-bar + HTTP/vsock app that wraps this library ships
/// from the main Spooktacular repo as `SpooktacularGuestTools`
/// — see `Sources/SpooktacularGuestTools/` in the root repo.
///
/// License: MIT. Depends on our open-source `SpiceProtocol`
/// and `SpiceSerialTransport` packages.
let package = Package(
    name: "SpiceGuestAgent",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "SpiceClipboardAgent",
            targets: ["SpiceClipboardAgent"]
        ),
    ],
    dependencies: [
        .package(path: "../SpiceProtocol"),
        .package(path: "../SpiceSerialTransport"),
    ],
    targets: [
        .target(
            name: "SpiceClipboardAgent",
            dependencies: [
                .product(name: "SpiceProtocol", package: "SpiceProtocol"),
                .product(
                    name: "SpiceSerialTransport",
                    package: "SpiceSerialTransport"
                ),
            ]
        ),
        .testTarget(
            name: "SpiceClipboardAgentTests",
            dependencies: ["SpiceClipboardAgent"]
        ),
    ]
)
