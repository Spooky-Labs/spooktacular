import Testing
import Foundation
@testable import SpooktacularKit
@testable import SpooktacularInfrastructureApple
@testable import SpooktacularApplication
@testable import SpooktacularCore

@Suite("SharedFolderProvisioner", .tags(.infrastructure))
struct SharedFolderProvisionerTests {

    // MARK: - Staging Directory

    @Test("Staging directory is inside the bundle with correct name", .timeLimit(.minutes(1)))
    func stagingDirectoryLocation() throws {
        let tmp = TempDirectory()
        let bundle = try VirtualMachineBundle.create(
            at: tmp.file("inner.vm"),
            spec: VirtualMachineSpecification()
        )

        let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
        #expect(staging.path.hasPrefix(bundle.url.path))
        #expect(staging.lastPathComponent == "shared-provisioning")
    }

    // MARK: - Provision

    @Suite("Provision", .tags(.infrastructure))
    struct ProvisionTests {

        private func setup(
            scriptContent: String = "#!/bin/bash\necho hello"
        ) throws -> (bundle: VirtualMachineBundle, scriptURL: URL, tmp: TempDirectory) {
            let tmp = TempDirectory()
            let scriptURL = tmp.file("setup.sh")
            try scriptContent.write(to: scriptURL, atomically: true, encoding: .utf8)
            let bundle = try VirtualMachineBundle.create(
                at: tmp.file("my-vm.vm"),
                spec: VirtualMachineSpecification()
            )
            return (bundle, scriptURL, tmp)
        }

        @Test("Script is copied to staging directory with correct content", .timeLimit(.minutes(1)))
        func scriptCopied() throws {
            let (bundle, scriptURL, _tmp) = try setup()
            try SharedFolderProvisioner.provision(script: scriptURL, bundle: bundle)

            let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
            let copiedScript = staging.appendingPathComponent(SharedFolderProvisioner.scriptFileName)
            let content = try String(contentsOf: copiedScript, encoding: .utf8)
            #expect(content.contains("echo hello"))
        }

        @Test("Script has executable permissions (0o755)", .timeLimit(.minutes(1)))
        func scriptExecutable() throws {
            let (bundle, scriptURL, _tmp) = try setup(scriptContent: "#!/bin/bash\necho test")
            try SharedFolderProvisioner.provision(script: scriptURL, bundle: bundle)

            let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
            let copiedScript = staging.appendingPathComponent(SharedFolderProvisioner.scriptFileName)
            let attrs = try FileManager.default.attributesOfItem(atPath: copiedScript.path)
            let permissions = try #require(attrs[.posixPermissions] as? Int)
            #expect(permissions == 0o755)
        }

        @Test("Trigger file is created and empty", .timeLimit(.minutes(1)))
        func triggerFileCreated() throws {
            let (bundle, scriptURL, _tmp) = try setup(scriptContent: "#!/bin/bash")
            try SharedFolderProvisioner.provision(script: scriptURL, bundle: bundle)

            let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
            let trigger = staging.appendingPathComponent(SharedFolderProvisioner.triggerFileName)
            let triggerExists = FileManager.default.fileExists(atPath: trigger.path)
            try #require(triggerExists, "Trigger file must exist")

            let data = try Data(contentsOf: trigger)
            #expect(data.isEmpty)
        }

        @Test("Missing script throws scriptNotFound", .timeLimit(.minutes(1)))
        func missingScriptThrows() throws {
            let tmp = TempDirectory()
            let bundle = try VirtualMachineBundle.create(
                at: tmp.file("missing-vm.vm"),
                spec: VirtualMachineSpecification()
            )

            let bogusScript = tmp.file("does-not-exist.sh")
            #expect(throws: SharedFolderProvisionerError.self) {
                try SharedFolderProvisioner.provision(script: bogusScript, bundle: bundle)
            }
        }

        @Test("Re-provisioning replaces existing script", .timeLimit(.minutes(1)))
        func replacesExistingScript() throws {
            let tmp = TempDirectory()
            let bundle = try VirtualMachineBundle.create(
                at: tmp.file("replace-vm.vm"),
                spec: VirtualMachineSpecification()
            )

            let script1 = tmp.file("first.sh")
            try "#!/bin/bash\necho first".write(to: script1, atomically: true, encoding: .utf8)
            try SharedFolderProvisioner.provision(script: script1, bundle: bundle)

            let script2 = tmp.file("second.sh")
            try "#!/bin/bash\necho second".write(to: script2, atomically: true, encoding: .utf8)
            try SharedFolderProvisioner.provision(script: script2, bundle: bundle)

            let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
            let copiedScript = staging.appendingPathComponent(SharedFolderProvisioner.scriptFileName)
            let content = try String(contentsOf: copiedScript, encoding: .utf8)
            #expect(content.contains("second"))
            #expect(!content.contains("first"))
        }
    }

    // MARK: - Watcher Plist

    @Suite("Watcher plist", .tags(.infrastructure))
    struct WatcherPlistTests {

        private func parsedPlist() throws -> [String: Any] {
            let plist = SharedFolderProvisioner.watcherPlist()
            let data = try #require(plist.data(using: .utf8))
            return try #require(
                try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            )
        }

        @Test("Is valid XML")
        func isValidXML() throws {
            _ = try parsedPlist()
        }

        @Test("Has correct Label matching constant")
        func label() throws {
            let dict = try parsedPlist()
            let label = try #require(dict["Label"] as? String)
            #expect(label == SharedFolderProvisioner.watcherLabel)
        }

        @Test("Has correct StartInterval matching constant")
        func interval() throws {
            let dict = try parsedPlist()
            let interval = try #require(dict["StartInterval"] as? Int)
            #expect(interval == SharedFolderProvisioner.watcherInterval)
        }

        @Test("RunAtLoad is true")
        func runsAtLoad() throws {
            let dict = try parsedPlist()
            let runAtLoad = try #require(dict["RunAtLoad"] as? Bool)
            #expect(runAtLoad == true)
        }

        @Test("Uses /bin/bash as first program argument")
        func usesBash() throws {
            let dict = try parsedPlist()
            let args = try #require(dict["ProgramArguments"] as? [String])
            #expect(args.first == "/bin/bash")
        }

        @Test("References the shared files volume")
        func referencesSharedVolume() {
            let plist = SharedFolderProvisioner.watcherPlist()
            #expect(plist.contains("/Volumes/My Shared Files/"))
        }
    }

    // MARK: - Watcher Install Script

    @Suite("Watcher install script", .tags(.infrastructure))
    struct WatcherInstallScriptTests {

        @Test("Is a valid bash script")
        func isBash() {
            #expect(SharedFolderProvisioner.watcherInstallScript().hasPrefix("#!/bin/bash"))
        }

        @Test("References the watcher label and launchctl")
        func referencesLabelAndLaunchctl() {
            let script = SharedFolderProvisioner.watcherInstallScript()
            #expect(script.contains(SharedFolderProvisioner.watcherLabel))
            #expect(script.contains("launchctl"))
        }
    }

    // MARK: - Constants

    @Test("Watcher label is a reverse-DNS string")
    func watcherLabelFormat() {
        let label = SharedFolderProvisioner.watcherLabel
        #expect(label.hasPrefix("com.spooktacular."))
        #expect(!label.contains(" "))
    }

    // MARK: - SharedFolderProvisionerError

    @Test("SharedFolderProvisionerError is equatable")
    func errorEquatable() {
        #expect(
            SharedFolderProvisionerError.scriptNotFound(path: "/a")
            == SharedFolderProvisionerError.scriptNotFound(path: "/a")
        )
        #expect(
            SharedFolderProvisionerError.scriptNotFound(path: "/a")
            != SharedFolderProvisionerError.scriptNotFound(path: "/b")
        )
        #expect(
            SharedFolderProvisionerError.stagingDirectoryFailed(path: "/x")
            == SharedFolderProvisionerError.stagingDirectoryFailed(path: "/x")
        )
    }
}
