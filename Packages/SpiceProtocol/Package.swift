// swift-tools-version: 6.2
import PackageDescription

/// # SpiceProtocol
///
/// A pure-Swift implementation of the SPICE `vd_agent` wire
/// protocol — the binary format spoken between a SPICE guest
/// agent and the SPICE host (in our case Apple's
/// `VZSpiceAgentPortAttachment`).
///
/// This package is **intentionally dependency-free**. It models
/// the protocol's bytes, nothing more — no serial port I/O, no
/// NSPasteboard, no UI. Those live in higher-level packages
/// (`SpiceSerialTransport`, `SpiceGuestAgent`) so this one stays
/// portable, testable, and reusable by any Swift app embedding
/// a SPICE endpoint (host side, guest side, or middle-box).
///
/// ## References
///
/// - [SPICE agent protocol specification](https://www.spice-space.org/agent-protocol.html)
/// - [spice/vd_agent.h header](https://gitlab.freedesktop.org/spice/spice-protocol/-/blob/master/spice/vd_agent.h)
/// - [Apple VZSpiceAgentPortAttachment](https://developer.apple.com/documentation/virtualization/vzspiceagentportattachment)
///
/// ## Licensing
///
/// MIT. The protocol itself is a public specification; this
/// is a clean-room Swift implementation written from the
/// spice-space.org documentation — it does not derive from
/// any GPL-licensed reference code (`spice-vdagent`,
/// `utmapp/vd_agent`).
let package = Package(
    name: "SpiceProtocol",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SpiceProtocol", targets: ["SpiceProtocol"]),
    ],
    targets: [
        .target(name: "SpiceProtocol"),
        .testTarget(
            name: "SpiceProtocolTests",
            dependencies: ["SpiceProtocol"]
        ),
    ]
)
