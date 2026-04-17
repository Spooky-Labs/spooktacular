import ArgumentParser
import SpooktacularKit

// MARK: - ArgumentParser Conformance

extension NetworkMode: ExpressibleByArgument {

    /// ArgumentParser calls this with a single positional/option
    /// value. It expects a failable initializer, so we map the
    /// throwing ``NetworkMode/init(serialized:)`` error surface to
    /// `nil` — ArgumentParser then produces its standard
    /// "invalid --network value" diagnostic against the user.
    public init?(argument: String) {
        do {
            self = try NetworkMode(serialized: argument)
        } catch {
            return nil
        }
    }
}
