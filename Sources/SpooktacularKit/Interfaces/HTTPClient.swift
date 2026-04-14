import Foundation

/// Abstracts HTTP communication so use cases don't depend on `URLSession`.
///
/// The Infrastructure layer provides a ``URLSessionHTTPClient``
/// implementation. Tests inject a mock.
///
/// ## Clean Architecture
///
/// Use cases define WHAT data they need from external systems. The
/// ``HTTPClient`` protocol is the port; the concrete transport is
/// the adapter. ``GitHubRunnerService`` depends on this protocol,
/// not on `URLSession` directly.
public protocol HTTPClient: Sendable {
    /// Executes an HTTP request and returns the response.
    ///
    /// - Parameter request: A fully configured URL request.
    /// - Returns: The response data and HTTP response metadata.
    /// - Throws: On network errors or invalid responses.
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}
