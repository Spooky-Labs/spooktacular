import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularInfrastructureApple

/// Bundle directories are named by UUID, so anything that labels a VM has to
/// read ``VirtualMachineMetadata/displayName``. Deriving the label from the
/// directory basename — which `spook list` used to do — printed raw UUIDs in
/// the NAME column and emitted `name == id` in `--json`.
@Suite("Bundle display-name resolution", .tags(.lifecycle))
struct BundleDisplayNameResolutionTests {

    /// Mirrors production naming: the directory is the VM's UUID, never its label.
    private func makeBundle(
        in temp: TempDirectory,
        named displayName: String
    ) throws -> VirtualMachineBundle {
        let bundle = try VirtualMachineBundle.create(
            at: temp.file("\(UUID().uuidString).vm"),
            spec: VirtualMachineSpecification(),
            displayName: displayName
        )
        return bundle
    }

    @Test("a bundle's directory basename is not its name", .timeLimit(.minutes(1)))
    func directoryBasenameIsNotTheName() throws {
        let temp = TempDirectory()
        let bundle = try makeBundle(in: temp, named: "ci-runner-01")

        let directoryLabel = bundle.url.deletingPathExtension().lastPathComponent

        #expect(
            directoryLabel != bundle.metadata.displayName,
            "the directory is a UUID; a label taken from it would show that UUID"
        )
        #expect(UUID(uuidString: directoryLabel) != nil, "the directory really is a UUID")
        #expect(bundle.metadata.displayName == "ci-runner-01")
    }

    @Test("a reloaded bundle still reports the name it was created with", .timeLimit(.minutes(1)))
    func loadedBundleReportsItsDisplayName() throws {
        let temp = TempDirectory()
        let created = try makeBundle(in: temp, named: "ci-runner-01")

        let reloaded = try VirtualMachineBundle.load(from: created.url)

        #expect(reloaded.metadata.displayName == "ci-runner-01")
    }

    @Test("VMs sharing a display name stay distinguishable by id", .timeLimit(.minutes(1)))
    func duplicateDisplayNamesRemainDistinct() throws {
        // Nothing stops two VMs carrying the same label, which is why the
        // per-VM IP lookup in `spook list` is keyed by id rather than by name.
        let temp = TempDirectory()
        let first = try makeBundle(in: temp, named: "dev")
        let second = try makeBundle(in: temp, named: "dev")

        #expect(first.metadata.displayName == second.metadata.displayName)
        #expect(first.metadata.id != second.metadata.id)

        var ipByID: [UUID: String] = [:]
        ipByID[first.metadata.id] = "192.168.64.3"
        ipByID[second.metadata.id] = "192.168.65.3"

        #expect(ipByID.count == 2, "keying by id keeps both addresses")
    }
}
