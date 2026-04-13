import ArgumentParser
import SpooktacularKit

// MARK: - ArgumentParser Conformance

extension NetworkMode: ExpressibleByArgument {

    public init?(argument: String) {
        switch argument {
        case "nat": self = .nat
        case "isolated": self = .isolated
        default:
            if argument.hasPrefix("bridged:") {
                self = .bridged(interface: String(argument.dropFirst("bridged:".count)))
            } else {
                return nil
            }
        }
    }
}
