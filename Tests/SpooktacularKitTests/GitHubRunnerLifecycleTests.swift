import Testing
import Foundation
@testable import SpooktacularApplication
@testable import SpooktacularCore

// MARK: - Scope validation

@Suite("GitHubRunnerScope validation")
struct GitHubRunnerScopeTests {

    @Test("accepts repo scope")
    func repoScope() throws {
        let scope = try GitHubRunnerScope("repos/acme/widgets")
        #expect(scope.rawValue == "repos/acme/widgets")
        if case .repo(let owner, let name) = scope.kind {
            #expect(owner == "acme")
            #expect(name == "widgets")
        } else {
            Issue.record("Expected .repo kind")
        }
    }

    @Test("accepts org scope")
    func orgScope() throws {
        let scope = try GitHubRunnerScope("orgs/acme")
        if case .org(let org) = scope.kind {
            #expect(org == "acme")
        } else {
            Issue.record("Expected .org kind")
        }
    }

    @Test("accepts enterprise scope")
    func enterpriseScope() throws {
        let scope = try GitHubRunnerScope("enterprises/big-co")
        if case .enterprise(let e) = scope.kind {
            #expect(e == "big-co")
        } else {
            Issue.record("Expected .enterprise kind")
        }
    }

    @Test("rejects bad scopes",
          arguments: [
              "",
              "repos/acme",                   // missing repo name
              "repos/acme/widgets/extra",     // too many components
              "orgs",                         // missing org
              "orgs/acme/something",          // too many components for org
              "enterprises",
              "users/acme",                   // wrong prefix
              "repos//widgets",               // empty owner
              "/repos/acme/widgets",          // leading slash
              "repos/acme/widgets/",          // trailing slash
          ])
    func invalidScopes(raw: String) {
        #expect(throws: GitHubServiceError.self) {
            _ = try GitHubRunnerScope(raw)
        }
    }
}

// MARK: - Issued token ledger

@Suite("IssuedTokenLedger lifecycle")
struct IssuedTokenLedgerTests {

    @Test("tracks and drops")
    func trackDrop() async {
        let ledger = IssuedTokenLedger()
        let h = await ledger.track(scope: "repos/a/b", token: "tok")
        #expect(await ledger.trackedCount == 1)
        #expect(await ledger.token(for: h) == "tok")
        await ledger.drop(h)
        #expect(await ledger.trackedCount == 0)
        #expect(await ledger.token(for: h) == nil)
    }

    @Test("sweeps expired tokens")
    func sweepExpired() async {
        let ledger = IssuedTokenLedger()
        let base = Date(timeIntervalSince1970: 10_000)
        _ = await ledger.track(scope: "repos/a/b", token: "stale", at: base)
        _ = await ledger.track(scope: "repos/a/b", token: "fresh",
                               at: base.addingTimeInterval(3500))
        #expect(await ledger.trackedCount == 2)
        let purged = await ledger.sweepExpired(
            now: base.addingTimeInterval(3600),
            ttl: 3600
        )
        #expect(purged == 1)
        #expect(await ledger.trackedCount == 1)
    }
}

// MARK: - Registration token service behavior

/// Records every request the service makes so tests can pin the
/// URL + method pair and inject canned responses.
private actor RecordingHTTPClient: HTTPClient {
    var requests: [DomainHTTPRequest] = []
    var nextResponses: [DomainHTTPResponse] = []

    func queue(_ response: DomainHTTPResponse) {
        nextResponses.append(response)
    }

    func execute(_ request: DomainHTTPRequest) async throws -> DomainHTTPResponse {
        requests.append(request)
        guard !nextResponses.isEmpty else {
            return DomainHTTPResponse(statusCode: 500)
        }
        return nextResponses.removeFirst()
    }
}

@Suite("GitHubRunnerService — lifecycle")
struct GitHubRunnerServiceLifecycleTests {

    private static func makeService(
        http: any HTTPClient
    ) -> GitHubRunnerService {
        GitHubRunnerService(
            auth: GitHubPATAuth(token: "ghp_test"),
            http: http
        )
    }

    @Test("issue → revoke drops the in-memory token")
    func issueAndRevoke() async throws {
        let http = RecordingHTTPClient()
        await http.queue(DomainHTTPResponse(
            statusCode: 201,
            body: Data(#"{"token":"LLBMS-FAKE","expires_at":"2020-01-22T20:13:35Z"}"#.utf8)
        ))
        let service = Self.makeService(http: http)
        let scope = try GitHubRunnerScope("repos/acme/widgets")
        let issued = try await service.issueRegistrationToken(scope: scope)
        #expect(issued.token == "LLBMS-FAKE")
        #expect(await service.trackedTokenCount() == 1)
        await service.revokeRegistrationToken(handle: issued.handle)
        #expect(await service.trackedTokenCount() == 0)
    }

    @Test("createRegistrationToken(scope:) rejects malformed scopes")
    func createRejectsInvalidScope() async {
        let http = RecordingHTTPClient()
        let service = Self.makeService(http: http)
        await #expect(throws: GitHubServiceError.self) {
            _ = try await service.createRegistrationToken(scope: "badformat")
        }
    }

    @Test("waitForDrain returns when runner is idle")
    func drainIdle() async throws {
        let http = RecordingHTTPClient()
        await http.queue(DomainHTTPResponse(
            statusCode: 200,
            body: Data(#"{"id":42,"name":"runner-001","status":"online","busy":false}"#.utf8)
        ))
        let service = Self.makeService(http: http)
        let scope = try GitHubRunnerScope("repos/a/b")
        try await service.waitForDrain(
            runnerId: 42,
            scope: scope,
            deadline: Date().addingTimeInterval(60),
            pollInterval: 0,
            clock: { Date() },
            sleep: { _ in }
        )
    }

    @Test("waitForDrain treats 404 as already-removed")
    func drain404() async throws {
        let http = RecordingHTTPClient()
        await http.queue(DomainHTTPResponse(
            statusCode: 404,
            body: Data("{}".utf8)
        ))
        let service = Self.makeService(http: http)
        let scope = try GitHubRunnerScope("repos/a/b")
        try await service.waitForDrain(
            runnerId: 42,
            scope: scope,
            deadline: Date().addingTimeInterval(60),
            pollInterval: 0,
            clock: { Date() },
            sleep: { _ in }
        )
    }

    @Test("waitForDrain throws at deadline when busy forever")
    func drainDeadline() async throws {
        let http = RecordingHTTPClient()
        // Inject many busy responses so the loop runs.
        for _ in 0..<5 {
            await http.queue(DomainHTTPResponse(
                statusCode: 200,
                body: Data(#"{"id":42,"name":"r","status":"online","busy":true}"#.utf8)
            ))
        }
        let service = Self.makeService(http: http)
        let scope = try GitHubRunnerScope("repos/a/b")
        // Clock increments by 10s per call so deadline arrives quickly.
        let state = ManualClock(start: Date(timeIntervalSince1970: 0))
        let deadline = Date(timeIntervalSince1970: 5)
        await #expect(throws: GitHubServiceError.self) {
            try await service.waitForDrain(
                runnerId: 42,
                scope: scope,
                deadline: deadline,
                pollInterval: 0,
                clock: { state.now() },
                sleep: { _ in state.advance(by: 2) }
            )
        }
    }
}

/// Step-able clock for drain tests.
final class ManualClock: @unchecked Sendable {
    private var current: Date
    private let lock = NSLock()
    init(start: Date) { self.current = start }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}
