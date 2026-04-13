import ArgumentParser

/// The Spooktacular command-line interface.
///
/// Manages macOS virtual machines on Apple Silicon.
@main
struct Spook: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spook",
        abstract: "Manage macOS virtual machines on Apple Silicon.",
        version: "0.1.0",
        subcommands: [
            Create.self,
            Start.self,
            Stop.self,
            List.self,
            Clone.self,
            Delete.self,
            IP.self,
            Set.self,
            Get.self,
            Snapshot.self,
            Restore.self,
            Snapshots.self,
            Share.self,
            SSH.self,
            Exec.self,
            Service.self,
            Serve.self,
        ],
        defaultSubcommand: List.self
    )
}
