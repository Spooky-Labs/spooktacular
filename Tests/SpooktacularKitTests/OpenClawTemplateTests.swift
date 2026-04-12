import Testing
import Foundation
@testable import SpooktacularKit

@Suite("OpenClawTemplate")
struct OpenClawTemplateTests {

    // MARK: - Script Content

    @Test("Script starts with a shebang line")
    func hasShebang() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    @Test("Script uses set -euo pipefail for safety")
    func strictMode() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("set -euo pipefail"))
    }

    @Test("Script installs Homebrew")
    func installsHomebrew() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("Homebrew/install/HEAD/install.sh"))
    }

    @Test("Script configures Homebrew shell environment")
    func configuresBrewShellenv() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("/opt/homebrew/bin/brew shellenv"))
    }

    @Test("Script installs Node.js 24 via Homebrew")
    func installsNode() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("brew install node@24"))
    }

    @Test("Script adds Node.js to PATH")
    func addsNodeToPath() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("/opt/homebrew/opt/node@24/bin"))
    }

    @Test("Script installs OpenClaw via npm")
    func installsOpenClaw() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("npm install -g openclaw@latest"))
    }

    @Test("Script installs the gateway daemon")
    func installsDaemon() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("openclaw onboard --install-daemon"))
    }

    @Test("Script prints completion message with port number")
    func printsCompletion() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("OpenClaw installed and running on port 18789"))
    }

    @Test("Script skips Homebrew install if already present")
    func skipsBrewIfPresent() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("if ! command -v brew"))
    }

    @Test("Script uses NONINTERACTIVE mode for Homebrew")
    func noninteractiveBrew() {
        let script = OpenClawTemplate.scriptContent()
        #expect(script.contains("NONINTERACTIVE=1"))
    }

    // MARK: - File Generation

    @Test("generate() creates a file on disk")
    func generatesFile() throws {
        let url = try OpenClawTemplate.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Generated file is executable")
    func fileIsExecutable() throws {
        let url = try OpenClawTemplate.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test("Generated file content matches scriptContent()")
    func fileContentMatchesScript() throws {
        let url = try OpenClawTemplate.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fileContent = try String(contentsOf: url, encoding: .utf8)
        let expected = OpenClawTemplate.scriptContent()
        #expect(fileContent == expected)
    }
}
