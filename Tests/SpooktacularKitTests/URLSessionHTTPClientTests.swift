import Testing
import Foundation
import Synchronization
import SpooktacularCore
import SpooktacularInfrastructureApple

/// Exercises ``URLSessionHTTPClient`` — the production ``HTTPClient``
/// conformance that carries every GitHub API call (registration-token
/// minting via `GitHubRunnerService`) — through the real `URLSession`
/// machinery against an in-process `URLProtocol` stub. No sockets are
/// opened and no real network is touched: the stub is registered only
/// on an ephemeral `URLSessionConfiguration`, never globally.
///
/// The suite is `.serialized` because the stub's canned outcome and
/// captured request live in shared static storage.
@Suite("URLSessionHTTPClient", .serialized)
struct URLSessionHTTPClientTests {

    /// A client whose session resolves every request through
    /// ``StubURLProtocol`` instead of the network.
    private static func makeClient() -> URLSessionHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionHTTPClient(session: URLSession(configuration: configuration))
    }

    @Test("POST round-trips method, URL, headers, body, and timeout; response translates back")
    func postRoundTrip() async throws {
        StubURLProtocol.install(.success(
            statusCode: 201,
            headers: ["X-GitHub-Request-Id": "ABC:123"],
            body: Data(#"{"token":"REG-FAKE"}"#.utf8)
        ))
        let url = try #require(
            URL(string: "https://api.github.com/repos/o/r/actions/runners/registration-token")
        )
        let request = DomainHTTPRequest(
            method: .post,
            url: url,
            headers: [
                "Authorization": "Bearer ghp_test",
                "Accept": "application/vnd.github+json",
            ],
            body: Data(#"{"probe":true}"#.utf8),
            timeout: 42
        )

        let response = try await Self.makeClient().execute(request)

        // Domain response translated back from HTTPURLResponse:
        // status preserved, header keys lowercased, body byte-for-byte.
        #expect(response.statusCode == 201)
        #expect(response.isSuccess)
        #expect(response.headers["x-github-request-id"] == "ABC:123")
        #expect(response.body == Data(#"{"token":"REG-FAKE"}"#.utf8))

        // The URLRequest the transport actually saw carries everything
        // the domain request specified.
        let seen = try #require(StubURLProtocol.captured)
        #expect(seen.url == url)
        #expect(seen.method == "POST")
        #expect(seen.headers["Authorization"] == "Bearer ghp_test")
        #expect(seen.headers["Accept"] == "application/vnd.github+json")
        #expect(seen.body == Data(#"{"probe":true}"#.utf8))
        #expect(seen.timeout == 42)
    }

    @Test("transport-level failure surfaces as a thrown error, not a fabricated response")
    func transportErrorPropagates() async throws {
        StubURLProtocol.install(.failure(URLError(.notConnectedToInternet)))
        let url = try #require(URL(string: "https://api.github.com/meta"))
        let request = DomainHTTPRequest(method: .get, url: url)

        await #expect(throws: (any Error).self) {
            _ = try await Self.makeClient().execute(request)
        }
    }
}

// MARK: - URLProtocol stub

/// Intercepts every request on sessions that register it and replies
/// with a canned ``Outcome`` — the standard Foundation seam for
/// testing `URLSession`-backed transports without the network.
private final class StubURLProtocol: URLProtocol {

    /// What the stub does with the next intercepted request.
    enum Outcome: Sendable {
        case success(statusCode: Int, headers: [String: String], body: Data)
        case failure(URLError)
    }

    /// The transport-level facts of the intercepted `URLRequest`,
    /// snapshotted for assertions.
    struct CapturedRequest: Sendable {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?
        let timeout: TimeInterval
    }

    private struct State: Sendable {
        var outcome: Outcome?
        var captured: CapturedRequest?
    }

    private static let state = Mutex(State())

    /// Arms the stub for the next request and clears any previous capture.
    static func install(_ outcome: Outcome) {
        state.withLock {
            $0.outcome = outcome
            $0.captured = nil
        }
    }

    /// The most recently intercepted request, if any.
    static var captured: CapturedRequest? {
        state.withLock { $0.captured }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession hands URLProtocol the body as a stream, never as
        // `httpBody` — drain it to assert on the posted bytes.
        let snapshot = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.drain(request.httpBodyStream),
            timeout: request.timeoutInterval
        )
        let outcome = Self.state.withLock { state -> Outcome? in
            state.captured = snapshot
            return state.outcome
        }

        switch outcome {
        case .success(let statusCode, let headers, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
        }
    }

    override func stopLoading() {
        // Nothing to cancel — startLoading replies synchronously.
    }

    /// Reads an `InputStream` to exhaustion, returning `nil` for
    /// body-less requests.
    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
