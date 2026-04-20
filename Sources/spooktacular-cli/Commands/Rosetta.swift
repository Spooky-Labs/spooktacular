import ArgumentParser
import Foundation
import SpooktacularApplication
@preconcurrency import Virtualization

/// Rosetta guest-side setup utility.
///
/// `spooktacular rosetta setup` prints the guest-side bash
/// script that activates Rosetta 2 in a running Linux VM —
/// mounting the virtio-fs share and registering the
/// runtime with binfmt_misc.  Apple's documentation is
/// explicit that this activation must happen inside the
/// guest; we can't script it from the host.  This command
/// produces the exact script from
/// [Apple's docs](https://developer.apple.com/documentation/virtualization/running-intel-binaries-in-linux-vms-with-rosetta)
/// so users can pipe it through `ssh`, copy-paste it into
/// the guest terminal, or feed it into the existing
/// user-data provisioning flow.
///
/// Also exposes `spooktacular rosetta status` to report
/// whether Rosetta is installed on the host, so operators
/// can preflight before creating Rosetta-enabled VMs.
struct Rosetta: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rosetta",
        abstract: "Rosetta 2 utilities for Linux guests.",
        subcommands: [Setup.self, Status.self],
        defaultSubcommand: Status.self
    )

    // MARK: - setup

    struct Setup: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "setup",
            abstract: "Print the guest-side script that activates Rosetta in a Linux VM.",
            discussion: """
                Apple's Virtualization framework can expose Rosetta to a \
                Linux guest via `VZLinuxRosettaDirectoryShare`, but the \
                final activation steps (mount the share, register the \
                runtime with `binfmt_misc`) must run inside the guest. \
                This command prints the exact script Apple documents \
                for those steps.

                Typical usage:
                  # Pipe directly into a running VM via SSH
                  spooktacular rosetta setup | ssh user@<vm-ip> sudo bash

                  # Save to disk and pass to the existing user-data flow
                  spooktacular rosetta setup > rosetta.sh
                  spooktacular start <vm> --user-data rosetta.sh --provision ssh

                The script is idempotent — running it twice is a no-op.
                """
        )

        func run() throws {
            print(LinuxRosettaTemplate.scriptContent())
        }
    }

    // MARK: - status

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status",
            abstract: "Report Rosetta availability on this host.",
            discussion: """
                Maps directly to `VZLinuxRosettaDirectoryShare.availability`.
                Exit status is 0 when Rosetta is installed, 1 otherwise
                — suitable for shell gates like
                `spooktacular rosetta status && spooktacular create ...`.
                """
        )

        func run() throws {
            let availability = VZLinuxRosettaDirectoryShare.availability
            switch availability {
            case .installed:
                print(Style.success("✓ Rosetta is installed and ready for Linux guests."))
            case .notInstalled:
                print(Style.warning("✗ Rosetta is not installed on this Mac."))
                print(Style.dim("  Install it once with: softwareupdate --install-rosetta"))
                throw ExitCode.failure
            case .notSupported:
                print(Style.error("✗ Rosetta is not supported by this host's hardware or macOS version."))
                throw ExitCode.failure
            @unknown default:
                print(Style.warning("Rosetta availability: unknown (framework returned an unrecognised case)."))
                throw ExitCode.failure
            }
        }
    }
}
