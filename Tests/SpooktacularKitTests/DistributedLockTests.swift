import Testing
import Foundation
@testable import SpookCore

@Suite("DistributedLock", .tags(.infrastructure))
struct DistributedLockTests {

    @Test("Lease reports expired when past expiresAt")
    func leaseExpired() {
        let lease = DistributedLease(
            name: "test",
            holder: "h1",
            acquiredAt: Date.distantPast,
            duration: 1
        )
        #expect(lease.isExpired)
    }

    @Test("Lease reports active when before expiresAt")
    func leaseActive() {
        let lease = DistributedLease(name: "test", holder: "h1", duration: 3600)
        #expect(!lease.isExpired)
    }

    @Test("Lease encodes and decodes with correct field values")
    func leaseCodable() throws {
        let lease = DistributedLease(name: "cap-lock", holder: "node-01", duration: 15)
        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(DistributedLease.self, from: data)
        #expect(decoded.name == "cap-lock")
        #expect(decoded.holder == "node-01")
    }
}
