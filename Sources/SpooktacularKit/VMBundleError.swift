import Foundation

/// An error that occurs during VM bundle operations.
///
/// Each case carries the ``url`` of the bundle that caused
/// the error, providing context for diagnostics and logging.
/// Conforms to `LocalizedError` so that `.localizedDescription`
/// returns the same user-facing message in the CLI, GUI, API,
/// and Kubernetes operator.
public enum VMBundleError: Error, Sendable, Equatable, LocalizedError {

    /// The bundle directory does not exist at the given URL.
    ///
    /// - Parameter url: The path that was expected to contain
    ///   a `.vm` bundle directory.
    case notFound(url: URL)

    /// A bundle already exists at the given URL.
    ///
    /// Returned when ``VMBundle/create(at:spec:)`` is called
    /// with a path that is already occupied.
    ///
    /// - Parameter url: The path where the bundle already exists.
    case alreadyExists(url: URL)

    /// The bundle's configuration file could not be read or parsed.
    ///
    /// - Parameter url: The path to the bundle whose
    ///   `config.json` is missing or malformed.
    case invalidConfiguration(url: URL)

    /// The bundle's metadata file could not be read or parsed.
    ///
    /// - Parameter url: The path to the bundle whose
    ///   `metadata.json` is missing or malformed.
    case invalidMetadata(url: URL)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notFound(let url):
            "VM bundle not found at \(url.lastPathComponent)."
        case .alreadyExists(let url):
            "A VM bundle already exists at \(url.lastPathComponent)."
        case .invalidConfiguration(let url):
            "Invalid configuration in VM bundle \(url.lastPathComponent). The config.json file is missing or corrupt."
        case .invalidMetadata(let url):
            "Invalid metadata in VM bundle \(url.lastPathComponent). The metadata.json file is missing or corrupt."
        }
    }
}
