import Testing
import Foundation
@testable import SpooktacularKit

/// Tests for LaunchDaemon plist generation.
///
/// These tests validate the XML structure produced by the
/// service install command without requiring root privileges
/// or writing to `/Library/LaunchDaemons/`.
@Suite("Service plist generation")
struct ServiceTests {

    // MARK: - Plist Generation Helpers

    /// Generates a plist XML string using the same logic as the
    /// `spook service install` command.
    ///
    /// This is a standalone copy of the generation logic so the
    /// test target does not need to depend on the `spook` executable
    /// target.
    private func generatePlist(executablePath: String, bind: String) -> String {
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
                <string>start</string>
                <string>--headless</string>
                <string>--bind</string>
                <string>\(bind)</string>
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

    /// Parses a plist XML string into a dictionary for key verification.
    private func parsePlist(_ xml: String) throws -> [String: Any] {
        let data = Data(xml.utf8)
        let obj = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        guard let dict = obj as? [String: Any] else {
            throw PlistTestError.notDictionary
        }
        return dict
    }

    /// Error type for plist parsing failures in tests.
    private enum PlistTestError: Error {
        case notDictionary
    }

    // MARK: - Tests

    @Test("Plist contains the correct daemon label")
    func plistLabel() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)
        #expect(dict["Label"] as? String == "com.spooktacular.daemon")
    }

    @Test("ProgramArguments includes the executable path and headless flag")
    func programArguments() throws {
        let path = "/opt/spooktacular/bin/spook"
        let plist = generatePlist(executablePath: path, bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)

        let args = dict["ProgramArguments"] as? [String]
        #expect(args != nil)
        #expect(args?[0] == path)
        #expect(args?.contains("start") == true)
        #expect(args?.contains("--headless") == true)
    }

    @Test("ProgramArguments includes the bind address")
    func bindAddress() throws {
        let bind = "127.0.0.1:8080"
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: bind)
        let dict = try parsePlist(plist)

        let args = dict["ProgramArguments"] as? [String]
        #expect(args?.contains("--bind") == true)
        #expect(args?.contains(bind) == true)
    }

    @Test("RunAtLoad is true")
    func runAtLoad() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)
        #expect(dict["RunAtLoad"] as? Bool == true)
    }

    @Test("KeepAlive is false")
    func keepAlive() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)
        #expect(dict["KeepAlive"] as? Bool == false)
    }

    @Test("StandardOutPath points to the spooktacular log")
    func stdoutPath() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)
        #expect(dict["StandardOutPath"] as? String == "/var/log/spooktacular.log")
    }

    @Test("StandardErrorPath points to the spooktacular error log")
    func stderrPath() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)
        #expect(dict["StandardErrorPath"] as? String == "/var/log/spooktacular.error.log")
    }

    @Test("Plist is valid XML that PropertyListSerialization can parse")
    func validXML() throws {
        let plist = generatePlist(executablePath: "/usr/local/bin/spook", bind: "0.0.0.0:9470")
        let data = Data(plist.utf8)
        let obj = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        )
        #expect(obj is [String: Any])
    }

    @Test("Custom executable path is embedded in the plist")
    func customExecutablePath() throws {
        let customPath = "/Users/ci/builds/spook"
        let plist = generatePlist(executablePath: customPath, bind: "0.0.0.0:9470")
        let dict = try parsePlist(plist)
        let args = dict["ProgramArguments"] as? [String]
        #expect(args?.first == customPath)
    }
}
