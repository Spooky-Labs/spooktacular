import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple
@testable import SpookApplication
@testable import SpookCore

/// Tests for per-VM LaunchDaemon plist generation.
@Suite("Service plist generation")
struct ServiceTests {

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

    // MARK: - Per-VM Label

    @Test("Plist label includes the VM name")
    func plistLabelIncludesVMName() throws {
        let plist = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let dictionary = try parsePlist(plist)
        #expect(dictionary["Label"] as? String == "com.spooktacular.vm.runner-01")
    }

    @Test("Different VM names produce different labels")
    func differentVMNamesDifferentLabels() throws {
        let plist1 = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let plist2 = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-02"
        )
        let dict1 = try parsePlist(plist1)
        let dict2 = try parsePlist(plist2)
        #expect(dict1["Label"] as? String != dict2["Label"] as? String)
    }

    // MARK: - ProgramArguments

    @Test("ProgramArguments includes the VM name")
    func programArgumentsIncludesVMName() throws {
        let plist = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "ci-worker"
        )
        let dictionary = try parsePlist(plist)
        let arguments = dictionary["ProgramArguments"] as? [String]
        #expect(arguments?.contains("ci-worker") == true)
    }

    @Test("ProgramArguments runs 'start <name> --headless'")
    func programArgumentsStartHeadless() throws {
        let path = "/opt/spooktacular/bin/spook"
        let plist = ServicePlist.generate(
            executablePath: path,
            vmName: "runner-01"
        )
        let dictionary = try parsePlist(plist)
        let arguments = dictionary["ProgramArguments"] as? [String]
        #expect(arguments == [path, "start", "runner-01", "--headless"])
    }

    @Test("Different VM names produce different ProgramArguments")
    func differentVMNamesDifferentArguments() throws {
        let plist1 = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let plist2 = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-02"
        )
        let dict1 = try parsePlist(plist1)
        let dict2 = try parsePlist(plist2)
        let args1 = dict1["ProgramArguments"] as? [String]
        let args2 = dict2["ProgramArguments"] as? [String]
        #expect(args1 != args2)
        #expect(args1?.contains("runner-01") == true)
        #expect(args2?.contains("runner-02") == true)
    }

    @Test("Custom executable path is embedded in ProgramArguments")
    func customExecutablePath() throws {
        let customPath = "/Users/ci/builds/spook"
        let plist = ServicePlist.generate(
            executablePath: customPath,
            vmName: "test-vm"
        )
        let dictionary = try parsePlist(plist)
        let arguments = dictionary["ProgramArguments"] as? [String]
        #expect(arguments?.first == customPath)
    }

    // MARK: - Standard Properties

    @Test("RunAtLoad is true")
    func runAtLoad() throws {
        let plist = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let dictionary = try parsePlist(plist)
        #expect(dictionary["RunAtLoad"] as? Bool == true)
    }

    @Test("KeepAlive is false")
    func keepAlive() throws {
        let plist = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let dictionary = try parsePlist(plist)
        #expect(dictionary["KeepAlive"] as? Bool == false)
    }

    @Test("Log paths include the VM name")
    func logPathsIncludeVMName() throws {
        let plist = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let dictionary = try parsePlist(plist)
        #expect(dictionary["StandardOutPath"] as? String == "/var/log/spooktacular.runner-01.log")
        #expect(dictionary["StandardErrorPath"] as? String == "/var/log/spooktacular.runner-01.error.log")
    }

    // MARK: - Plist Validity

    @Test("Plist is valid XML")
    func validXML() throws {
        let plist = ServicePlist.generate(
            executablePath: "/usr/local/bin/spook",
            vmName: "runner-01"
        )
        let data = Data(plist.utf8)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        #expect(object is [String: Any])
    }

    // MARK: - Helper Functions

    @Test("label(for:) returns correct label")
    func labelHelper() {
        #expect(ServicePlist.label(for: "runner-01") == "com.spooktacular.vm.runner-01")
        #expect(ServicePlist.label(for: "ci-worker") == "com.spooktacular.vm.ci-worker")
    }

    @Test("plistPath(for:) returns correct path")
    func plistPathHelper() {
        #expect(
            ServicePlist.plistPath(for: "runner-01")
                == "/Library/LaunchDaemons/com.spooktacular.vm.runner-01.plist"
        )
    }
}
