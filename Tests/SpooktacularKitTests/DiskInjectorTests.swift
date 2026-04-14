import Testing
import Foundation
@testable import SpooktacularKit

@Suite("DiskInjector")
struct DiskInjectorTests {

    // MARK: - LaunchDaemon Plist Generation

    @Test("Generated plist is valid XML")
    func plistIsValidXML() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        let data = try #require(plist.data(using: .utf8))
        // PropertyListSerialization will throw if the XML is malformed.
        let parsed = try PropertyListSerialization.propertyList(
            from: data, format: nil
        )
        #expect(parsed is [String: Any])
    }

    @Test("Generated plist has correct Label")
    func plistHasCorrectLabel() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let label = try #require(dict["Label"] as? String)
        #expect(label == "com.spooktacular.user-data")
    }

    @Test("Generated plist has correct ProgramArguments")
    func plistHasCorrectProgramArguments() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let args = try #require(dict["ProgramArguments"] as? [String])
        #expect(args == ["/bin/bash", "/usr/local/bin/spooktacular-user-data.sh"])
    }

    @Test("Generated plist runs at load")
    func plistRunsAtLoad() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let runAtLoad = try #require(dict["RunAtLoad"] as? Bool)
        #expect(runAtLoad == true)
    }

    @Test("Generated plist has stdout log path")
    func plistHasStdoutPath() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let stdoutPath = try #require(dict["StandardOutPath"] as? String)
        #expect(stdoutPath == "/var/log/spooktacular-user-data.log")
    }

    @Test("Generated plist has stderr log path")
    func plistHasStderrPath() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let stderrPath = try #require(dict["StandardErrorPath"] as? String)
        #expect(stderrPath == "/var/log/spooktacular-user-data.error.log")
    }

    @Test("Generated plist contains XML declaration")
    func plistHasXMLDeclaration() {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        #expect(plist.hasPrefix("<?xml"))
    }

    @Test("Generated plist contains DOCTYPE")
    func plistHasDOCTYPE() {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        #expect(plist.contains("<!DOCTYPE plist"))
    }

    @Test("Daemon label constant matches plist Label")
    func daemonLabelMatchesPlist() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        #expect(plist.contains(DiskInjector.daemonLabel))
    }

    @Test("Guest script path constant matches plist ProgramArguments")
    func guestScriptPathMatchesPlist() throws {
        let plist = DiskInjector.generateLaunchDaemonPlist()
        #expect(plist.contains(DiskInjector.guestScriptPath))
    }

    // MARK: - hdiutil Plist Parsing

    @Test("parseDeviceFromPlist extracts device from valid GUID_partition_scheme")
    func parseDeviceFromValidPlist() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>content-hint</key>
                    <string>GUID_partition_scheme</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4</string>
                </dict>
                <dict>
                    <key>content-hint</key>
                    <string>Apple_APFS</string>
                    <key>dev-entry</key>
                    <string>/dev/disk4s1</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let device = DiskInjector.parseDeviceFromPlist(xml)
        #expect(device == "/dev/disk4")
    }

    @Test("parseDeviceFromPlist falls back to first dev-entry")
    func parseDeviceFallback() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>system-entities</key>
            <array>
                <dict>
                    <key>content-hint</key>
                    <string>Apple_APFS</string>
                    <key>dev-entry</key>
                    <string>/dev/disk5s1</string>
                </dict>
            </array>
        </dict>
        </plist>
        """
        let device = DiskInjector.parseDeviceFromPlist(xml)
        #expect(device == "/dev/disk5s1")
    }

    @Test("parseDeviceFromPlist returns nil for invalid input")
    func parseDeviceReturnsNilForInvalid() {
        #expect(DiskInjector.parseDeviceFromPlist("not a plist") == nil)
        #expect(DiskInjector.parseDeviceFromPlist("") == nil)
    }

    // MARK: - DiskInjectorError

    @Test("DiskInjectorError cases have non-empty descriptions")
    func allErrorCasesDescribed() {
        let cases: [DiskInjectorError] = [
            .diskImageNotFound(path: "/test"),
            .scriptNotFound(path: "/test"),
            .mountFailed(reason: "test"),
            .processFailed(command: "test", exitCode: 1),
        ]
        for error in cases {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    @Test("DiskInjectorError cases have recovery suggestions")
    func allErrorCasesHaveRecovery() {
        let cases: [DiskInjectorError] = [
            .diskImageNotFound(path: "/test"),
            .scriptNotFound(path: "/test"),
            .mountFailed(reason: "test"),
            .processFailed(command: "test", exitCode: 1),
        ]
        for error in cases {
            #expect(error.recoverySuggestion != nil)
            #expect(!error.recoverySuggestion!.isEmpty)
        }
    }

    @Test("DiskInjectorError is equatable")
    func errorEquatable() {
        #expect(
            DiskInjectorError.diskImageNotFound(path: "/a")
            == DiskInjectorError.diskImageNotFound(path: "/a")
        )
        #expect(
            DiskInjectorError.diskImageNotFound(path: "/a")
            != DiskInjectorError.diskImageNotFound(path: "/b")
        )
        #expect(
            DiskInjectorError.mountFailed(reason: "x")
            == DiskInjectorError.mountFailed(reason: "x")
        )
        #expect(
            DiskInjectorError.processFailed(command: "a", exitCode: 1)
            == DiskInjectorError.processFailed(command: "a", exitCode: 1)
        )
        #expect(
            DiskInjectorError.processFailed(command: "a", exitCode: 1)
            != DiskInjectorError.processFailed(command: "a", exitCode: 2)
        )
    }

    @Test("diskImageNotFound error includes path in description")
    func diskImageNotFoundIncludesPath() {
        let error = DiskInjectorError.diskImageNotFound(path: "/foo/disk.img")
        #expect(error.localizedDescription.contains("/foo/disk.img"))
    }

    @Test("scriptNotFound error includes path in description")
    func scriptNotFoundIncludesPath() {
        let error = DiskInjectorError.scriptNotFound(path: "/bar/setup.sh")
        #expect(error.localizedDescription.contains("/bar/setup.sh"))
    }

    @Test("processFailed error includes exit code in description")
    func processFailedIncludesExitCode() {
        let error = DiskInjectorError.processFailed(command: "hdiutil attach", exitCode: 42)
        #expect(error.localizedDescription.contains("42"))
    }
}
