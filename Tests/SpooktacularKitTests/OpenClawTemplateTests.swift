import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("OpenClaw Template", .tags(.template))
struct OpenClawTemplateTests {

    @Suite("Script Structure")
    struct Structure {
        @Test("starts with bash shebang", arguments: [GuestOS.macOS, .linux])
        func shebang(os: GuestOS) {
            #expect(OpenClawTemplate.scriptContent(for: os, username: "admin")
                .hasPrefix("#!/bin/bash"))
        }

        @Test("uses set -euo pipefail for safety", arguments: [GuestOS.macOS, .linux])
        func strictMode(os: GuestOS) {
            #expect(OpenClawTemplate.scriptContent(for: os, username: "admin")
                .contains("set -euo pipefail"))
        }
    }

    // The provisioner daemon (macOS) and cloud-init (Linux) run this
    // script AS ROOT on first boot — before any user session exists.
    // The old template began with the Homebrew installer, which refuses
    // to run as root: the flow died at step 1. These tests pin the
    // root-context-safe design.

    @Test("macOS script is root-context safe and uses OpenClaw's documented daemon install")
    func macOSRootSafe() {
        let script = OpenClawTemplate.scriptContent(for: .macOS, username: "admin")
        #expect(!script.contains("brew"))
        #expect(!script.contains("Homebrew"))
        #expect(script.contains("installer -pkg"))
        #expect(script.contains("nodejs.org/dist/index.json"))   // latest 24.x at runtime
        #expect(script.contains("OPENCLAW_USER=\"admin\""))
        #expect(script.contains("sudo -u \"$OPENCLAW_USER\""))
        // Uses OpenClaw's own `onboard --install-daemon` (documented),
        // not a hand-rolled LaunchDaemon running a `gateway` subcommand.
        #expect(script.contains("openclaw onboard --install-daemon"))
        #expect(!script.contains("/Library/LaunchDaemons/"))
    }

    @Test("linux script installs official arm64 tarball + documented daemon + headless linger")
    func linuxShape() {
        let script = OpenClawTemplate.scriptContent(for: .linux, username: "admin")
        #expect(script.contains("linux-arm64.tar.xz"))
        #expect(script.contains("/usr/local"))
        // Headless: user services need lingering; the daemon is
        // installed by OpenClaw itself, not a hand-rolled systemd unit.
        #expect(script.contains("loginctl enable-linger"))
        #expect(script.contains("openclaw onboard --install-daemon"))
        #expect(!script.contains("/etc/systemd/system/openclaw"))
        #expect(!script.contains("brew"))
        #expect(!script.contains("launchctl"))
    }

    @Test("both scripts install openclaw and wait for the provisioned account")
    func commonShape() {
        for os in [GuestOS.macOS, .linux] {
            let script = OpenClawTemplate.scriptContent(for: os, username: "admin")
            #expect(script.contains("npm install -g openclaw@latest"), "\(os)")
            #expect(script.contains("id \"$OPENCLAW_USER\""), "missing account wait for \(os)")
        }
    }

    @Suite("File Generation")
    struct FileGeneration {

        @Test("generates an executable file whose content matches scriptContent(for:username:)")
        func generatesExecutableFile() throws {
            let url = try OpenClawTemplate.generate(for: .macOS, username: "admin")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(FileManager.default.fileExists(atPath: url.path))

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try #require(attrs[.posixPermissions] as? Int)
            // Owner-only (0o700). The provisioning script may embed
            // secrets; no other local user should be able to read it.
            #expect(permissions == 0o700)

            let fileContent = try String(contentsOf: url, encoding: .utf8)
            #expect(fileContent == OpenClawTemplate.scriptContent(for: .macOS, username: "admin"))
        }
    }
}
