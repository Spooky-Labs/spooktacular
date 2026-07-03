import ArgumentParser
import Foundation
import SpooktacularKit

extension Spooktacular {

    /// Clones an existing virtual machine.
    struct Clone: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clone a VM (instant copy-on-write).",
            discussion: """
                Creates an instant copy of a VM using APFS copy-on-write. \
                The clone shares disk blocks with the source — a 30 GB \
                disk clones in milliseconds. Each clone gets a fresh \
                machine identifier.

                EXAMPLES:
                  spook clone base runner-01
                  spook clone dev-env test-env
                """
        )

        @Argument(help: "Name of the source VM.")
        var source: String

        @Argument(help: "Name for the new clone.")
        var destination: String

        func run() async throws {
            try SpooktacularPaths.ensureDirectories()

            let sourceURL = try requireBundle(for: source)

            // Destination is a NEW bundle — mint a fresh UUID
            // for its directory name; the `destination` CLI
            // argument becomes the clone's display name, which
            // may overlap with the source or with any other VM.
            try SpooktacularPaths.validateDisplayName(destination)
            let destinationID = UUID()
            let destinationURL = SpooktacularPaths.bundleURL(for: destinationID)

            let sourceBundle = try VirtualMachineBundle.load(from: sourceURL)
            print(Style.info("⤢ Cloning '\(source)' → '\(destination)' (id=\(destinationID.uuidString))..."))

            let clone = try CloneManager.clone(
                source: sourceBundle,
                to: destinationURL,
                displayName: destination
            )

            print(Style.success("✓ Clone '\(destination)' created."))
            Style.field("UUID", Style.dim(clone.id.uuidString))
            Style.field("Machine ID", Style.dim("regenerated (unique)"))
            Style.field("Setup", clone.metadata.setupCompleted
                        ? Style.green("inherited") : Style.dim("pending"))
            print()
        }
    }
}
