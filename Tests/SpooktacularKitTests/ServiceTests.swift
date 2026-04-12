import Testing
import Foundation
@testable import SpooktacularKit

/// Tests for LaunchDaemon plist generation.
@Suite("Service plist generation")
struct ServiceTests {

    private func generatePlist(executablePath: String) -> String {
        let label = "com.spooktacular.daemon"
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executablePath)</string>
                <string>list</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <false/>
            <key>StandardOutPath</key>
            <string>/var/log/spooktacular.log</string>
            <key>StandardErrorPath</key>
            <string>/var/log/spooktacular.error.log</string>
        </dict>
        </plist>
        """
    }

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

    @Test("Plist contains the correct daemon label")
    func plistLabel() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook")
        let dictionary = try parsePlist(plist)
        #expect(dictionary["Label"] as? String == "com.spooktacular.daemon")
    }

    @Test("ProgramArguments includes the executable path")
    func programArguments() throws {
        let path = "/opt/spooktacular/bin/spook"
        let plist = generatePlist(executablePath: path)
        let dictionary = try parsePlist(plist)
        let arguments = dictionary["ProgramArguments"] as? [String]
        #expect(arguments?[0] == path)
        #expect(arguments?.contains("list") == true)
    }

    @Test("RunAtLoad is true")
    func runAtLoad() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook")
        let dictionary = try parsePlist(plist)
        #expect(dictionary["RunAtLoad"] as? Bool == true)
    }

    @Test("KeepAlive is false")
    func keepAlive() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook")
        let dictionary = try parsePlist(plist)
        #expect(dictionary["KeepAlive"] as? Bool == false)
    }

    @Test("StandardOutPath points to spooktacular log")
    func stdoutPath() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook")
        let dictionary = try parsePlist(plist)
        #expect(dictionary["StandardOutPath"] as? String == "/var/log/spooktacular.log")
    }

    @Test("StandardErrorPath points to spooktacular error log")
    func stderrPath() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook")
        let dictionary = try parsePlist(plist)
        #expect(dictionary["StandardErrorPath"] as? String == "/var/log/spooktacular.error.log")
    }

    @Test("Plist is valid XML")
    func validXML() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook")
        let data = Data(plist.utf8)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        #expect(object is [String: Any])
    }

    @Test("Custom executable path is embedded in the plist")
    func customExecutablePath() throws {
        let customPath = "/Users/ci/builds/spook"
        let plist = generatePlist(executablePath: customPath)
        let dictionary = try parsePlist(plist)
        let arguments = dictionary["ProgramArguments"] as? [String]
        #expect(arguments?.first == customPath)
    }
}
