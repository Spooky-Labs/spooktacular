import Foundation
import SpookCore
import SpookApplication

/// ``HTTPClient`` adapter over Foundation's `URLSession`.
///
/// Translates ``DomainHTTPRequest`` into `URLRequest`, drives
/// `URLSession`, and translates the resulting `HTTPURLResponse` back
/// into ``DomainHTTPResponse``. The only point in the codebase where
/// `URLSession` and the domain's HTTP types meet.
public struct URLSessionHTTPClient: HTTPClient {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: DomainHTTPRequest) async throws -> DomainHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let k = key as? String, let v = value as? String else { continue }
            headers[k.lowercased()] = v
        }

        return DomainHTTPResponse(
            statusCode: http.statusCode,
            headers: headers,
            body: data
        )
    }
}
