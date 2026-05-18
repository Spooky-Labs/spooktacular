// swift-tools-version: 6.0
//
// Minimal Linux guest agent for Spooktacular.
//
// Standalone package — it intentionally does NOT depend on the
// main repo's Apple-framework targets so it cross-compiles (or
// builds natively inside a Linux guest VM) with only the Swift
// standard library + Glibc.
//
// Build on Linux (inside the guest or via Docker):
//   cd LinuxAgent
//   swift build -c release
//
// The produced binary speaks the same HTTP-over-vsock wire
// protocol as the macOS agent so the host's
// `GuestAgentClient.eventStream()` connects to either guest
// without changes.

import PackageDescription

let package = Package(
    name: "SpooktacularAgentLinux",
    products: [
        .executable(
            name: "spooktacular-agent",
            targets: ["SpooktacularAgentLinux"]
        ),
    ],
    targets: [
        // Tiny C module exporting the AF_VSOCK / sockaddr_vm
        // symbols from <linux/vm_sockets.h>. Swift's Glibc
        // overlay does not re-export them, so we bridge with
        // a one-header shim.
        .target(
            name: "CLinuxVsock",
            path: "Sources/CLinuxVsock"
        ),
        .executableTarget(
            name: "SpooktacularAgentLinux",
            dependencies: ["CLinuxVsock"],
            path: "Sources/SpooktacularAgentLinux"
        ),
    ]
)
