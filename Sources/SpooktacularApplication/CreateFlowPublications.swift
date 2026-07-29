import Foundation
import SpooktacularCore

/// Combines template-supplied port publications with the operator's.
public enum CreateFlowPublications {

    /// Merges publication lists, letting the operator win.
    ///
    /// Templates contribute sensible defaults — the OpenClaw template
    /// publishes its gateway — but an explicit `--publish` for the same
    /// host port must replace the default rather than collide with it,
    /// because vmnet cannot hold two forwarding rules for one host
    /// port.
    ///
    /// - Parameters:
    ///   - template: Defaults contributed by the selected template.
    ///   - operatorPublications: Publications the operator asked for.
    /// - Returns: The operator's publications first, then any template
    ///   defaults whose host port is still free.
    public static func merge(
        template: [PortPublication],
        operator operatorPublications: [PortPublication]
    ) -> [PortPublication] {
        let claimed = Set(operatorPublications.map(\.hostPort))
        return operatorPublications + template.filter { !claimed.contains($0.hostPort) }
    }
}
