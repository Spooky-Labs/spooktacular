import Foundation

/// A domain-owned HTTP request value.
///
/// Describes WHAT an HTTP call looks like without exposing Foundation's
/// `URLRequest` or `URLSession` into the domain layer. Adapters
/// translate this into whatever transport they implement
/// (``URLSessionHTTPClient`` today; a `Network.framework` adapter
/// tomorrow).
public struct DomainHTTPRequest: Sendable {

    /// HTTP methods that domain code may invoke. Extend only when a
    /// concrete use case demands it.
    public enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
        case head = "HEAD"
        case options = "OPTIONS"
    }

    /// The HTTP method.
    public let method: Method

    /// The target URL.
    public let url: URL

    /// Request headers. Keys are preserved as given; adapters may
    /// normalize case as needed.
    public let headers: [String: String]

    /// The request body, if any.
    public let body: Data?

    /// Request timeout in seconds. `nil` uses the adapter's default.
    public let timeout: TimeInterval?

    public init(
        method: Method,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

/// A domain-owned HTTP response value.
///
/// Carries the status code, response headers (lowercased keys), and
/// body bytes. Adapters translate from whatever concrete response type
/// their transport returned.
public struct DomainHTTPResponse: Sendable {

    /// The HTTP status code (e.g., `200`, `404`, `503`).
    public let statusCode: Int

    /// Response headers. Keys are lowercased.
    public let headers: [String: String]

    /// The response body.
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = .init()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    /// `true` if `statusCode` is in the range `200..<300`.
    public var isSuccess: Bool {
        (200..<300).contains(statusCode)
    }
}

/// Abstracts HTTP communication so use cases don't depend on `URLSession`.
///
/// The Infrastructure layer provides a ``URLSessionHTTPClient``
/// implementation. Tests inject a mock that returns canned
/// ``DomainHTTPResponse`` values.
///
/// ## Clean Architecture
///
/// Use cases define WHAT data they need from external systems. The
/// ``HTTPClient`` protocol is the port; the concrete transport is
/// the adapter. Callers build ``DomainHTTPRequest`` values and consume
/// ``DomainHTTPResponse`` values — neither `URLRequest` nor
/// `HTTPURLResponse` crosses the boundary.
public protocol HTTPClient: Sendable {

    /// Executes an HTTP request and returns the response.
    ///
    /// - Parameter request: The request to execute.
    /// - Returns: The response status, headers, and body.
    /// - Throws: On network errors, DNS failures, or when the adapter
    ///   cannot produce a response.
    func execute(_ request: DomainHTTPRequest) async throws -> DomainHTTPResponse
}
