import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("Remote Desktop Template", .tags(.template))
struct RemoteDesktopTemplateTests {

    let script = RemoteDesktopTemplate.scriptContent()

    @Suite("Script Structure")
    struct Structure {
        let script = RemoteDesktopTemplate.scriptContent()

        @Test("starts with bash shebang")
        func shebang() { #expect(script.hasPrefix("#!/bin/bash")) }

        @Test("uses set -euo pipefail for safety")
        func strictMode() { #expect(script.contains("set -euo pipefail")) }
    }

    @Test("script includes all required elements",
          arguments: [
              "ARDAgent.app/Contents/Resources/kickstart",
              "-activate",
              "-configure",
              "-access",
              "-on",
              "-privs",
              "-all",
              "launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist",
          ])
    func requiredElement(expected: String) {
        #expect(script.contains(expected), "Script missing: \(expected)")
    }

    @Suite("File Generation")
    struct FileGeneration {

        @Test("generates an executable file whose content matches scriptContent()")
        func generatesExecutableFile() throws {
            let url = try RemoteDesktopTemplate.generate()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(FileManager.default.fileExists(atPath: url.path))

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try #require(attrs[.posixPermissions] as? Int)
            // Owner-only (0o700). The provisioning script may embed
            // secrets; no other local user should be able to read it.
            #expect(permissions == 0o700)

            let fileContent = try String(contentsOf: url, encoding: .utf8)
            #expect(fileContent == RemoteDesktopTemplate.scriptContent())
        }
    }
}
