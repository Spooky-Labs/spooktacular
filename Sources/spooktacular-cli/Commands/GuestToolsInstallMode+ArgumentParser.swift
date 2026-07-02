import ArgumentParser
import SpooktacularKit

// MARK: - ArgumentParser Conformance

extension GuestToolsInstallMode: ExpressibleByArgument {

    /// ArgumentParser expects a failable initializer from a
    /// single CLI token. `GuestToolsInstallMode` is `String`-
    /// backed, so the raw-value initializer handles both
    /// accepted tokens directly — no alias layer needed now
    /// that the enum has been pared down to
    /// ``GuestToolsInstallMode/disabled`` and
    /// ``GuestToolsInstallMode/installed``.
    public init?(argument: String) {
        guard let value = GuestToolsInstallMode(rawValue: argument) else {
            return nil
        }
        self = value
    }

    /// Comma-separated list of accepted tokens for the
    /// ArgumentParser help text.
    public static var allValueStrings: [String] {
        GuestToolsInstallMode.allCases.map(\.rawValue)
    }
}
