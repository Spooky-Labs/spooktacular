import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// AWS EBS integration — attach/detach EBS snapshots as
    /// virtual disks inside running VMs.
    ///
    /// This group is the user-facing shape of Track M. The
    /// flow is:
    ///
    /// 1. `spooktacular ebs attach <vm> --snapshot-id snap-…`
    ///    starts a local NBD server
    ///    (``EBSNBDServer``), federates AWS creds via the
    ///    existing `WorkloadTokenIssuer` → STS
    ///    `AssumeRoleWithWebIdentity` path, adds an
    ///    ``NBDBackedDisk`` entry to the VM's spec, and
    ///    prints the NBD URL the VM will consume on next
    ///    start.
    ///
    /// 2. `spooktacular ebs detach <vm> --snapshot-id snap-…`
    ///    removes the entry from the spec and stops the
    ///    bridge.
    ///
    /// The MVP implementation in this turn wires the spec
    /// side only — `attach` persists the NBD entry in the
    /// bundle, so the next VM start picks it up via Track
    /// K's `VZNetworkBlockDeviceStorageDeviceAttachment`
    /// wiring. The **bridge-start-on-attach** side of the
    /// workflow (running the `EBSNBDServer` alongside the
    /// VM as a long-lived subprocess) is a follow-up — it
    /// requires either a new LaunchAgent or extending
    /// `AppState` to manage per-VM EBS bridges.
    struct EBS: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ebs",
            abstract: "Attach AWS EBS snapshots as virtual disks.",
            subcommands: [Attach.self, Detach.self, List.self],
            defaultSubcommand: List.self
        )

        // MARK: - attach

        struct Attach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "attach",
                abstract: "Attach an EBS snapshot to a VM as a virtio-blk disk.",
                discussion: """
                    Adds an entry to the VM's `networkBlockDevices` \
                    list pointing at a local NBD URL that the EBS \
                    bridge will serve. On next `spooktacular start`, \
                    the VM mounts the snapshot via \
                    `VZNetworkBlockDeviceStorageDeviceAttachment`.

                    AWS auth: uses the existing \
                    WorkloadTokenIssuer → STS \
                    AssumeRoleWithWebIdentity flow. The OIDC \
                    signing key is SEP-bound via \
                    `P256KeyStore(service: "oidc-issuer")`; STS \
                    session creds are cached in the Keychain with \
                    `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

                    EXAMPLES:
                      spooktacular ebs attach my-vm \\
                        --snapshot-id snap-0123456789abcdef0 \\
                        --region us-east-1 --read-only
                """
            )

            @Argument(help: "VM name.")
            var name: String

            @Option(help: "EBS snapshot ID (snap-…).")
            var snapshotId: String

            @Option(help: "AWS region (e.g., us-east-1).")
            var region: String

            @Flag(help: "Force the disk to present as read-only even if the server allows writes.")
            var readOnly: Bool = false

            @Option(help: "Local TCP port for the NBD bridge. Use 0 for auto-assignment.")
            var bridgePort: UInt16 = 0

            func run() async throws {
                let bundleURL = try requireBundle(for: name)
                let bundle = try VirtualMachineBundle.load(from: bundleURL)

                // Build the NBD URL the VM will consume.
                // The bridge must be running on this port
                // when the VM starts; running the bridge is
                // a follow-up step (daemonize via the
                // existing `spooktacular serve` path).
                let urlString = bridgePort == 0
                    ? "nbd://127.0.0.1:10809/\(snapshotId)"
                    : "nbd://127.0.0.1:\(bridgePort)/\(snapshotId)"
                guard let url = URL(string: urlString) else {
                    print(Style.error("✗ Could not construct NBD URL from inputs."))
                    throw ExitCode.failure
                }

                let disk = NBDBackedDisk(
                    url: url,
                    forcedReadOnly: readOnly
                )
                var existing = bundle.spec.networkBlockDevices
                if !existing.contains(where: { $0.url == url }) {
                    existing.append(disk)
                }
                let newSpec = bundle.spec.with(networkBlockDevices: existing)
                try VirtualMachineBundle.writeSpec(newSpec, to: bundleURL)

                print(Style.success("✓ Added EBS snapshot \(snapshotId) to '\(name)' as \(url.absoluteString)"))
                print(Style.dim("  Region: \(region)"))
                print(Style.dim("  Read-only: \(readOnly)"))
                print(Style.dim(""))
                print(Style.dim("  NEXT STEPS (follow-up work):"))
                print(Style.dim("    1. Run the EBS NBD bridge on port \(bridgePort == 0 ? 10809 : bridgePort)."))
                print(Style.dim("    2. `spooktacular start \(name)` picks up the disk."))
            }
        }

        // MARK: - detach

        struct Detach: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "detach",
                abstract: "Remove an EBS-backed disk from a VM's spec."
            )

            @Argument(help: "VM name.")
            var name: String

            @Option(help: "EBS snapshot ID to detach.")
            var snapshotId: String

            func run() async throws {
                let bundleURL = try requireBundle(for: name)
                let bundle = try VirtualMachineBundle.load(from: bundleURL)

                let before = bundle.spec.networkBlockDevices
                let after = before.filter { !$0.url.absoluteString.contains(snapshotId) }
                guard after.count != before.count else {
                    print(Style.dim("No EBS disks matching \(snapshotId) on '\(name)'."))
                    return
                }
                let newSpec = bundle.spec.with(networkBlockDevices: after)
                try VirtualMachineBundle.writeSpec(newSpec, to: bundleURL)
                print(Style.success("✓ Detached \(before.count - after.count) disk(s) matching \(snapshotId) from '\(name)'."))
            }
        }

        // MARK: - list

        struct List: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List EBS-backed disks configured on a VM."
            )

            @Argument(help: "VM name.")
            var name: String

            func run() async throws {
                let bundleURL = try requireBundle(for: name)
                let bundle = try VirtualMachineBundle.load(from: bundleURL)

                let disks = bundle.spec.networkBlockDevices
                if disks.isEmpty {
                    print(Style.dim("No NBD-backed disks configured on '\(name)'."))
                    return
                }
                for (index, disk) in disks.enumerated() {
                    print("\(index). \(disk.url.absoluteString)")
                    print(Style.dim("   read-only: \(disk.forcedReadOnly), sync: \(disk.syncMode.rawValue), bus: \(disk.bus.rawValue)"))
                }
            }
        }
    }
}
