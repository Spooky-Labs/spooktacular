import ArgumentParser
import SpooktacularKit

// MARK: - ArgumentParser Conformance

extension NetworkMode: ExpressibleByArgument {

    public init?(argument: String) {
        self.init(serialized: argument)
    }
}
