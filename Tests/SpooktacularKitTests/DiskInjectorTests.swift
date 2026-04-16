import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpookInfrastructureApple

@Suite("DiskInjector", .tags(.infrastructure))
struct DiskInjectorTests {

    // MARK: - LaunchDaemon Plist Generation

    @Suite("LaunchDaemon plist", .tags(.infrastructure))
    struct LaunchDaemonPlistTests {

        /// Parses the generated plist once, used by parameterized tests.
        private func parsedPlist() throws -> [String: Any] {
            let plist = DiskInjector.generateLaunchDaemonPlist()
            let data = try #require(plist.data(using: .utf8))
            return try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
        }

        @Test("Generated plist is valid XML")
        func plistIsValidXML() throws {
            _ = try parsedPlist()
        }

        @Test(
            "Plist contains expected keys and values",
            arguments: [
                ("Label", "com.spooktacular.user-data"),
                ("StandardOutPath", "/var/log/spooktacular-user-data.log"),
                ("StandardErrorPath", "/var/log/spooktacular-user-data.error.log"),
            ]
        )
        func plistStringValue(key: String, expected: String) throws {
            let dict = try parsedPlist()
            let value = try #require(dict[key] as? String)
            #expect(value == expected)
        }

        @Test("RunAtLoad is true")
        func plistRunsAtLoad() throws {
            let dict = try parsedPlist()
            let runAtLoad = try #require(dict["RunAtLoad"] as? Bool)
            #expect(runAtLoad == true)
        }

        @Test("ProgramArguments are correct")
        func plistHasCorrectProgramArguments() throws {
            let dict = try parsedPlist()
            let args = try #require(dict["ProgramArguments"] as? [String])
            #expect(args == ["/bin/bash", "/usr/local/bin/spooktacular-user-data.sh"])
        }

        @Test("Daemon label and guest script path constants match plist content")
        func constantsMatchPlist() {
            let plist = DiskInjector.generateLaunchDaemonPlist()
            #expect(plist.contains(DiskInjector.daemonLabel))
            #expect(plist.contains(DiskInjector.guestScriptPath))
        }
    }

    // MARK: - hdiutil Plist Parsing

    @Suite("parseDeviceFromPlist", .tags(.infrastructure))
    struct ParseDeviceTests {

        @Test("Extracts device from valid GUID_partition_scheme")
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
            #expect(DiskInjector.parseDeviceFromPlist(xml) == "/dev/disk4")
        }

        @Test("Falls back to first dev-entry when no GUID_partition_scheme")
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
            #expect(DiskInjector.parseDeviceFromPlist(xml) == "/dev/disk5s1")
        }

        @Test(
            "Returns nil for invalid input",
            arguments: ["not a plist", ""]
        )
        func parseDeviceReturnsNilForInvalid(input: String) {
            #expect(DiskInjector.parseDeviceFromPlist(input) == nil)
        }
    }

    // MARK: - DiskInjectorError

    @Suite("DiskInjectorError", .tags(.infrastructure))
    struct DiskInjectorErrorTests {

        @Test("Is equatable across cases")
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
    }
}
