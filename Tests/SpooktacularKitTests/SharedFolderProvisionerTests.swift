import Testing
import Foundation
@testable import SpooktacularKit

@Suite("SharedFolderProvisioner")
struct SharedFolderProvisionerTests {

    // MARK: - Staging Directory

    @Test("Staging directory is inside the bundle")
    func stagingDirectoryLocation() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).vm")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let spec = VirtualMachineSpecification()
        let bundle = try VirtualMachineBundle.create(at: bundleURL.appendingPathComponent("inner.vm"), spec: spec)

        let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
        #expect(staging.path.hasPrefix(bundle.url.path))
        #expect(staging.lastPathComponent == "shared-provisioning")
    }

    // MARK: - Provision

    @Test("Script is copied to staging directory")
    func scriptCopied() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a test script.
        let scriptURL = tempDir.appendingPathComponent("setup.sh")
        try "#!/bin/bash\necho hello".write(to: scriptURL, atomically: true, encoding: .utf8)

        // Create a VM bundle.
        let bundleURL = tempDir.appendingPathComponent("my-vm.vm")
        let spec = VirtualMachineSpecification()
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

        // Provision.
        try SharedFolderProvisioner.provision(script: scriptURL, bundle: bundle)

        // Verify the script was copied.
        let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
        let copiedScript = staging.appendingPathComponent(SharedFolderProvisioner.scriptFileName)
        #expect(FileManager.default.fileExists(atPath: copiedScript.path))

        let content = try String(contentsOf: copiedScript, encoding: .utf8)
        #expect(content.contains("echo hello"))
    }

    @Test("Script has executable permissions")
    func scriptExecutable() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("setup.sh")
        try "#!/bin/bash\necho test".write(to: scriptURL, atomically: true, encoding: .utf8)

        let bundleURL = tempDir.appendingPathComponent("exec-vm.vm")
        let spec = VirtualMachineSpecification()
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

        try SharedFolderProvisioner.provision(script: scriptURL, bundle: bundle)

        let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
        let copiedScript = staging.appendingPathComponent(SharedFolderProvisioner.scriptFileName)
        let attrs = try FileManager.default.attributesOfItem(atPath: copiedScript.path)
        let permissions = attrs[.posixPermissions] as? Int
        #expect(permissions == 0o755)
    }

    @Test("Trigger file is created")
    func triggerFileCreated() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let scriptURL = tempDir.appendingPathComponent("setup.sh")
        try "#!/bin/bash".write(to: scriptURL, atomically: true, encoding: .utf8)

        let bundleURL = tempDir.appendingPathComponent("trigger-vm.vm")
        let spec = VirtualMachineSpecification()
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

        try SharedFolderProvisioner.provision(script: scriptURL, bundle: bundle)

        let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
        let trigger = staging.appendingPathComponent(SharedFolderProvisioner.triggerFileName)
        #expect(FileManager.default.fileExists(atPath: trigger.path))

        // Trigger file should be empty.
        let data = try Data(contentsOf: trigger)
        #expect(data.isEmpty)
    }

    @Test("Provisioning with missing script throws scriptNotFound")
    func missingScriptThrows() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("missing-vm.vm")
        let spec = VirtualMachineSpecification()
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

        let bogusScript = tempDir.appendingPathComponent("does-not-exist.sh")
        #expect(throws: SharedFolderProvisionerError.self) {
            try SharedFolderProvisioner.provision(script: bogusScript, bundle: bundle)
        }
    }

    @Test("Provisioning replaces existing script")
    func replacesExistingScript() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let bundleURL = tempDir.appendingPathComponent("replace-vm.vm")
        let spec = VirtualMachineSpecification()
        let bundle = try VirtualMachineBundle.create(at: bundleURL, spec: spec)

        // First provision.
        let script1 = tempDir.appendingPathComponent("first.sh")
        try "#!/bin/bash\necho first".write(to: script1, atomically: true, encoding: .utf8)
        try SharedFolderProvisioner.provision(script: script1, bundle: bundle)

        // Second provision with different content.
        let script2 = tempDir.appendingPathComponent("second.sh")
        try "#!/bin/bash\necho second".write(to: script2, atomically: true, encoding: .utf8)
        try SharedFolderProvisioner.provision(script: script2, bundle: bundle)

        let staging = SharedFolderProvisioner.stagingDirectory(for: bundle)
        let copiedScript = staging.appendingPathComponent(SharedFolderProvisioner.scriptFileName)
        let content = try String(contentsOf: copiedScript, encoding: .utf8)
        #expect(content.contains("second"))
        #expect(!content.contains("first"))
    }

    // MARK: - Watcher Plist

    @Test("Watcher plist is valid XML")
    func watcherPlistIsValidXML() throws {
        let plist = SharedFolderProvisioner.watcherPlist()
        let data = try #require(plist.data(using: .utf8))
        let parsed = try PropertyListSerialization.propertyList(
            from: data, format: nil
        )
        #expect(parsed is [String: Any])
    }

    @Test("Watcher plist has correct Label")
    func watcherPlistLabel() throws {
        let plist = SharedFolderProvisioner.watcherPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let label = try #require(dict["Label"] as? String)
        #expect(label == SharedFolderProvisioner.watcherLabel)
    }

    @Test("Watcher plist has correct StartInterval")
    func watcherPlistInterval() throws {
        let plist = SharedFolderProvisioner.watcherPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let interval = try #require(dict["StartInterval"] as? Int)
        #expect(interval == SharedFolderProvisioner.watcherInterval)
    }

    @Test("Watcher plist runs at load")
    func watcherPlistRunsAtLoad() throws {
        let plist = SharedFolderProvisioner.watcherPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let runAtLoad = try #require(dict["RunAtLoad"] as? Bool)
        #expect(runAtLoad == true)
    }

    @Test("Watcher plist uses /bin/bash")
    func watcherPlistUsesBash() throws {
        let plist = SharedFolderProvisioner.watcherPlist()
        let data = try #require(plist.data(using: .utf8))
        let dict = try #require(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let args = try #require(dict["ProgramArguments"] as? [String])
        #expect(args.first == "/bin/bash")
    }

    @Test("Watcher plist references the shared files volume")
    func watcherPlistReferencesSharedVolume() {
        let plist = SharedFolderProvisioner.watcherPlist()
        #expect(plist.contains("/Volumes/My Shared Files/"))
    }

    // MARK: - Watcher Install Script

    @Test("Watcher install script is a valid shell script")
    func installScriptIsBash() {
        let script = SharedFolderProvisioner.watcherInstallScript()
        #expect(script.hasPrefix("#!/bin/bash"))
    }

    @Test("Watcher install script references the watcher label")
    func installScriptReferencesLabel() {
        let script = SharedFolderProvisioner.watcherInstallScript()
        #expect(script.contains(SharedFolderProvisioner.watcherLabel))
    }

    @Test("Watcher install script uses launchctl")
    func installScriptUsesLaunchctl() {
        let script = SharedFolderProvisioner.watcherInstallScript()
        #expect(script.contains("launchctl"))
    }

    // MARK: - Constants

    @Test("Watcher label constant is a reverse-DNS string")
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
