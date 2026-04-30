import ArgumentParser

/// The Spooktacular command-line interface.
///
/// Manages macOS virtual machines on Apple Silicon.
@main
struct Spooktacular: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spooktacular",
        abstract: "Manage macOS virtual machines on Apple Silicon.",
        version: "1.0.1",
        subcommands: [
            Create.self,
            Start.self,
            Stop.self,
            Suspend.self,
            DiscardSuspend.self,
            Stream.self,
            Socket.self,
            Forward.self,
            EBS.self,
            List.self,
            Clone.self,
            Delete.self,
            IP.self,
            Set.self,
            Get.self,
            Snapshot.self,
            Share.self,
            SSH.self,
            Exec.self,
            Remote.self,
            Service.self,
            Serve.self,
            Doctor.self,
            RBAC.self,
            Bundle.self,
            BreakGlass.self,
            Egress.self,
            IAM.self,
            Identity.self,
            MDM.self,
            Incident.self,
            SignRequest.self,
            SecurityControls.self,
            SpooktacularAudit.self,
            Rosetta.self,
        ],
        defaultSubcommand: List.self
    )
}
