import Testing
import Foundation
@testable import SpooktacularCore
@testable import SpooktacularApplication
@testable import SpooktacularInfrastructureApple

/// Tests for the ``FleetSingleton`` port + its in-process
/// implementation. The DynamoDB adapter is exercised by
/// `EnterpriseIntegrationTests` when credentials are available;
/// here we pin the contract at the boundary.
@Suite("Fleet singleton", .tags(.security, .infrastructure))
struct FleetSingletonTests {

    @Test("first mark is fresh; second for the same id is alreadyConsumed")
    func singleMarkThenReplay() async throws {
        let s = InProcessFleetSingleton()
        let first = try await s.mark(id: "nonce-1", ttl: 300)
        #expect(first == .freshMark)
        let second = try await s.mark(id: "nonce-1", ttl: 300)
        #expect(second == .alreadyConsumed)
    }

    @Test("different ids are independent")
    func independentIDs() async throws {
        let s = InProcessFleetSingleton()
        #expect(try await s.mark(id: "a", ttl: 60) == .freshMark)
        #expect(try await s.mark(id: "b", ttl: 60) == .freshMark)
        #expect(try await s.mark(id: "a", ttl: 60) == .alreadyConsumed)
    }

    @Test("concurrent marks of the same id produce one fresh and N-1 consumed")
    func concurrentMarks() async throws {
        let s = InProcessFleetSingleton()
        let nonce = UUID().uuidString
        let outcomes = await withTaskGroup(of: MarkOutcome.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    (try? await s.mark(id: nonce, ttl: 60)) ?? .alreadyConsumed
                }
            }
            var results: [MarkOutcome] = []
            for await result in group { results.append(result) }
            return results
        }
        let fresh = outcomes.filter { $0 == .freshMark }.count
        let consumed = outcomes.filter { $0 == .alreadyConsumed }.count
        #expect(fresh == 1)
        #expect(consumed == outcomes.count - 1)
    }

    @Test("expired mark is claimable again by another id")
    func expiredMarksAreClaimable() async throws {
        let s = InProcessFleetSingleton()
        let first = try await s.mark(id: "short", ttl: 0.05)
        #expect(first == .freshMark)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        let after = try await s.mark(id: "short", ttl: 300)
        #expect(after == .freshMark, "Expired mark should be reclaimable")
    }

    @Test("mark outcomes are Equatable")
    func outcomeEquatable() {
        #expect(MarkOutcome.freshMark == MarkOutcome.freshMark)
        #expect(MarkOutcome.freshMark != MarkOutcome.alreadyConsumed)
    }
}
