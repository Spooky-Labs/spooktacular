import Testing
import Foundation
@testable import SpooktacularKit

@Suite("RemoteDesktopTemplate")
struct RemoteDesktopTemplateTests {

    // MARK: - Script Content

    @Test("Script starts with a shebang line")
    func hasShebang() {
        let script = RemoteDesktopTemplate.scriptContent()
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    @Test("Script uses set -euo pipefail for safety")
    func strictMode() {
        let script = RemoteDesktopTemplate.scriptContent()
        #expect(script.contains("set -euo pipefail"))
    }

    @Test("Script contains ARD kickstart command")
    func containsKickstart() {
        let script = RemoteDesktopTemplate.scriptContent()
        #expect(script.contains("ARDAgent.app/Contents/Resources/kickstart"))
    }

    @Test("Script activates and configures Screen Sharing")
    func activatesScreenSharing() {
        let script = RemoteDesktopTemplate.scriptContent()
        #expect(script.contains("-activate"))
        #expect(script.contains("-configure"))
        #expect(script.contains("-access"))
        #expect(script.contains("-on"))
        #expect(script.contains("-privs"))
        #expect(script.contains("-all"))
    }

    @Test("Script enables Remote Login (SSH)")
    func enablesSSH() {
        let script = RemoteDesktopTemplate.scriptContent()
        #expect(script.contains("systemsetup -setremotelogin on"))
    }

    @Test("Script prints VNC confirmation message")
    func printsConfirmation() {
        let script = RemoteDesktopTemplate.scriptContent()
        #expect(script.contains("Screen Sharing enabled. Connect via VNC."))
    }

    // MARK: - File Generation

    @Test("generate() creates a file on disk")
    func generatesFile() throws {
        let url = try RemoteDesktopTemplate.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Generated file is executable")
    func fileIsExecutable() throws {
        let url = try RemoteDesktopTemplate.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attrs[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test("Generated file content matches scriptContent()")
    func fileContentMatchesScript() throws {
        let url = try RemoteDesktopTemplate.generate()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fileContent = try String(contentsOf: url, encoding: .utf8)
        let expected = RemoteDesktopTemplate.scriptContent()
        #expect(fileContent == expected)
    }
}
