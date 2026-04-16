import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

@Suite("OpenClaw Template", .tags(.template))
struct OpenClawTemplateTests {

    let script = OpenClawTemplate.scriptContent()

    @Suite("Script Structure")
    struct Structure {
        let script = OpenClawTemplate.scriptContent()

        @Test("starts with bash shebang")
        func shebang() { #expect(script.hasPrefix("#!/bin/bash")) }

        @Test("uses set -euo pipefail for safety")
        func strictMode() { #expect(script.contains("set -euo pipefail")) }
    }

    @Test("script includes all required elements",
          arguments: [
              "Homebrew/install/HEAD/install.sh",
              "/opt/homebrew/bin/brew shellenv",
              "brew install node@24",
              "/opt/homebrew/opt/node@24/bin",
              "npm install -g openclaw@latest",
              "openclaw onboard --install-daemon",
              "NONINTERACTIVE=1",
              "if ! command -v brew",
          ])
    func requiredElement(expected: String) {
        #expect(script.contains(expected), "Script missing: \(expected)")
    }

    @Suite("File Generation")
    struct FileGeneration {

        @Test("generates an executable file whose content matches scriptContent()")
        func generatesExecutableFile() throws {
            let url = try OpenClawTemplate.generate()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            #expect(FileManager.default.fileExists(atPath: url.path))

            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let permissions = try #require(attrs[.posixPermissions] as? Int)
            #expect(permissions == 0o755)

            let fileContent = try String(contentsOf: url, encoding: .utf8)
            #expect(fileContent == OpenClawTemplate.scriptContent())
        }
    }
}
