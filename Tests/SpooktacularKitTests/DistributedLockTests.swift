import Testing
import Foundation
@testable import SpooktacularCore

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

    @Test("Fresh lease has renewalCount 0")
    func freshLeaseRenewalCountZero() {
        let lease = DistributedLease(name: "x", holder: "h", duration: 15)
        #expect(lease.renewalCount == 0)
    }

    @Test("renewalCount is preserved through Codable round-trip")
    func renewalCountRoundTrips() throws {
        let lease = DistributedLease(
            name: "x", holder: "h", duration: 15,
            version: 5, renewalCount: 37
        )
        let data = try JSONEncoder().encode(lease)
        let decoded = try JSONDecoder().decode(DistributedLease.self, from: data)
        #expect(decoded.renewalCount == 37)
        #expect(decoded.version == 5)
    }

    @Test("maxRenewals is 100 (documented contract)")
    func maxRenewalsConstant() {
        #expect(DistributedLease.maxRenewals == 100)
    }
}
