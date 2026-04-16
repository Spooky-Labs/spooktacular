import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

/// Tests for per-VM LaunchDaemon plist generation.
@Suite("Service Plist Generation", .tags(.infrastructure))
struct ServiceTests {

    private static let defaultPath = "/usr/local/bin/spook"
    private static let defaultVM = "runner-01"

    private func parsePlist(_ xml: String) throws -> [String: Any] {
        let data = Data(xml.utf8)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dictionary = object as? [String: Any] else {
            throw PlistTestError.notDictionary
        }
        return dictionary
    }

    private enum PlistTestError: Error {
        case notDictionary
    }

    // MARK: - Plist Validity

    @Test("generated plist is valid XML that parses as a dictionary")
    func validXML() throws {
        let plist = ServicePlist.generate(
            executablePath: Self.defaultPath, vmName: Self.defaultVM
        )
        let dictionary = try parsePlist(plist)
        #expect(!dictionary.isEmpty)
    }

    // MARK: - Standard Properties (Parameterized)

    @Test("plist contains expected standard properties",
          arguments: [
              ("Label", "com.spooktacular.vm.runner-01"),
              ("RunAtLoad", "true"),
              ("KeepAlive", "false"),
              ("StandardOutPath", "/var/log/spooktacular.runner-01.log"),
              ("StandardErrorPath", "/var/log/spooktacular.runner-01.error.log"),
          ] as [(String, String)])
    func standardProperty(key: String, expected: String) throws {
        let plist = ServicePlist.generate(
            executablePath: Self.defaultPath, vmName: Self.defaultVM
        )
        let dictionary = try parsePlist(plist)
        if let boolVal = dictionary[key] as? Bool {
            #expect(String(boolVal) == expected, "\(key) should be \(expected)")
        } else {
            let value = try #require(dictionary[key] as? String, "Missing key: \(key)")
            #expect(value == expected, "\(key) should be \(expected)")
        }
    }

    // MARK: - ProgramArguments

    @Suite("ProgramArguments")
    struct ProgramArguments {

        @Test("arguments are [path, start, vmName, --headless]")
        func fullArgumentList() throws {
            let path = "/opt/spooktacular/bin/spook"
            let plist = ServicePlist.generate(executablePath: path, vmName: "runner-01")
            let data = Data(plist.utf8)
            let dict = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as! [String: Any]
            let args = try #require(dict["ProgramArguments"] as? [String])
            #expect(args == [path, "start", "runner-01", "--headless"])
        }

        @Test("different VM names produce different arguments")
        func differentVMNames() throws {
            let plist1 = ServicePlist.generate(
                executablePath: "/usr/local/bin/spook", vmName: "runner-01"
            )
            let plist2 = ServicePlist.generate(
                executablePath: "/usr/local/bin/spook", vmName: "runner-02"
            )
            let dict1 = try PropertyListSerialization.propertyList(
                from: Data(plist1.utf8), options: [], format: nil
            ) as! [String: Any]
            let dict2 = try PropertyListSerialization.propertyList(
                from: Data(plist2.utf8), options: [], format: nil
            ) as! [String: Any]

            let args1 = try #require(dict1["ProgramArguments"] as? [String])
            let args2 = try #require(dict2["ProgramArguments"] as? [String])
            #expect(args1 != args2)
            #expect(args1.contains("runner-01"))
            #expect(args2.contains("runner-02"))
        }
    }

    // MARK: - Helper Functions

    @Suite("Helpers")
    struct Helpers {

        @Test("label(for:) returns prefixed label",
              arguments: [
                  ("runner-01", "com.spooktacular.vm.runner-01"),
                  ("ci-worker", "com.spooktacular.vm.ci-worker"),
              ] as [(String, String)])
        func labelHelper(vmName: String, expected: String) {
            #expect(ServicePlist.label(for: vmName) == expected)
        }

        @Test("plistPath(for:) returns LaunchDaemons path")
        func plistPathHelper() {
            #expect(
                ServicePlist.plistPath(for: "runner-01")
                    == "/Library/LaunchDaemons/com.spooktacular.vm.runner-01.plist"
            )
        }
    }
}
