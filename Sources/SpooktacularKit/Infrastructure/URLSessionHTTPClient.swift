import Foundation

/// Concrete ``HTTPClient`` using Foundation's `URLSession`.
///
/// This is the production implementation for HTTP communication.
/// Use cases like ``GitHubRunnerService`` depend on the ``HTTPClient``
/// protocol, not on `URLSession` directly.
public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}
