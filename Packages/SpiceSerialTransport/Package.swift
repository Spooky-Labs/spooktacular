// swift-tools-version: 6.2
import PackageDescription

/// # SpiceSerialTransport
///
/// Async Swift transport for the SPICE `vd_agent` protocol over
/// the virtio-serial port Apple's `VZSpiceAgentPortAttachment`
/// presents to a macOS guest at
/// `/dev/tty.com.redhat.spice.0`.
///
/// This package concerns itself with:
///
/// - Opening the device with POSIX-correct flags for a
///   bidirectional byte-stream (`O_RDWR | O_NONBLOCK | O_NOCTTY`).
/// - Putting the tty into raw mode so binary SPICE framing
///   isn't corrupted by line discipline (`cfmakeraw` +
///   `VMIN=1, VTIME=0`).
/// - Reading bytes without blocking the caller, via a
///   `DispatchSource.makeReadSource` bridged into an
///   `AsyncThrowingStream`.
/// - Reassembling SPICE frames across arbitrary read
///   boundaries — short reads are a documented reality on
///   virtio-serial devices; consumers see whole
///   `(VDIChunkHeader, VDAgentMessage, payload)` tuples only.
/// - Serializing writes through an `actor` so concurrent
///   callers can't interleave frames.
///
/// Depends on `SpiceProtocol` for the wire-format types.
///
/// License: MIT. Designed for open-sourcing as the first
/// Swift Concurrency–native SPICE transport for macOS.
let package = Package(
    name: "SpiceSerialTransport",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "SpiceSerialTransport",
            targets: ["SpiceSerialTransport"]
        ),
    ],
    dependencies: [
        .package(path: "../SpiceProtocol"),
    ],
    targets: [
        .target(
            name: "SpiceSerialTransport",
            dependencies: [
                .product(name: "SpiceProtocol", package: "SpiceProtocol"),
            ]
        ),
        .testTarget(
            name: "SpiceSerialTransportTests",
            dependencies: ["SpiceSerialTransport"]
        ),
    ]
)
