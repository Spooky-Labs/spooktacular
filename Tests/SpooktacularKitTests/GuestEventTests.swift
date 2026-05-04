import Foundation
import Testing
@testable import SpooktacularCore

/// Wire-format coverage for the multi-topic event stream.
///
/// These tests pin the exact JSON envelope (`topic` + `data`)
/// so the guest agent and host-side client agree on the shape
/// byte-for-byte. A regression in either side would surface
/// here.
@Suite("GuestEvent Codable envelope", .tags(.infrastructure))
struct GuestEventCodableTests {

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    @Test("stats event encodes with topic=stats and full payload")
    func encodesStats() throws {
        let snapshot = GuestStatsResponse(
            cpuUsage: 0.5,
            memoryUsedBytes: 4_000_000_000,
            memoryTotalBytes: 16_000_000_000,
            loadAverage1m: 1.2,
            processCount: 256,
            uptime: 3_600
        )
        let event: GuestEvent = .stats(snapshot)
        let data = try encoder.encode(event)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"topic\":\"stats\""))
        #expect(json.contains("\"cpuUsage\":0.5"))
        #expect(json.contains("\"memoryUsedBytes\":4000000000"))
    }

    @Test("ports event encodes with topic=ports and array payload")
    func encodesPorts() throws {
        let event: GuestEvent = .ports([
            GuestPortInfo(port: 8080, pid: 42, processName: "node"),
            GuestPortInfo(port: 5432, pid: 43, processName: "postgres"),
        ])
        let data = try encoder.encode(event)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"topic\":\"ports\""))
        #expect(json.contains("\"port\":8080"))
        #expect(json.contains("\"processName\":\"postgres\""))
    }

    @Test("appsFrontmost uses dotted topic name on the wire")
    func frontmostDottedTopic() throws {
        let event: GuestEvent = .appsFrontmost(
            GuestAppInfo(name: "Xcode", bundleID: "com.apple.dt.Xcode", isActive: true, pid: 99)
        )
        let data = try encoder.encode(event)
        let json = try #require(String(data: data, encoding: .utf8))
        // WWDC-visible on-the-wire spelling; underscore or
        // camelCase would break shell filtering.
        #expect(json.contains("\"topic\":\"apps.frontmost\""))
        #expect(json.contains("\"bundleID\":\"com.apple.dt.Xcode\""))
    }

    @Test("nil frontmost payload encodes without a data key")
    func frontmostNilIsOmitted() throws {
        let event: GuestEvent = .appsFrontmost(nil)
        let data = try encoder.encode(event)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"topic\":\"apps.frontmost\""))
        // `encodeIfPresent` drops the key entirely on nil —
        // clients that decode-if-present see no payload.
        #expect(!json.contains("\"data\":null"))
    }

    @Test("round-trip preserves every variant")
    func roundTrip() throws {
        let samples: [GuestEvent] = [
            .stats(GuestStatsResponse(
                cpuUsage: 0.0,
                memoryUsedBytes: 1_000_000_000,
                memoryTotalBytes: 2_000_000_000,
                loadAverage1m: 0,
                processCount: 1,
                uptime: 0
            )),
            .ports([]),
            .ports([GuestPortInfo(port: 1, pid: 1, processName: "init")]),
            .appsFrontmost(nil),
            .appsFrontmost(GuestAppInfo(name: "Finder", bundleID: "com.apple.finder", isActive: true, pid: 100)),
        ]

        let decoder = JSONDecoder()
        let encoder = self.encoder
        for original in samples {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(GuestEvent.self, from: data)
            #expect(decoded == original)
        }
    }

    @Test("cpuUsage == nil round-trips (first agent sample after boot)")
    func nilCPUUsageRoundTrips() throws {
        let event: GuestEvent = .stats(GuestStatsResponse(
            cpuUsage: nil,
            memoryUsedBytes: 0,
            memoryTotalBytes: 0,
            loadAverage1m: 0,
            processCount: 0,
            uptime: 0
        ))
        let data = try encoder.encode(event)
        let decoded = try JSONDecoder().decode(GuestEvent.self, from: data)
        #expect(decoded == event)
    }
}

@Suite("GuestEventFilter query parser", .tags(.infrastructure))
struct GuestEventFilterTests {

    @Test("nil or empty query yields the `all` filter")
    func emptyIsAll() {
        #expect(GuestEventFilter.parse(nil) == .all)
        #expect(GuestEventFilter.parse("") == .all)
    }

    @Test("parses all three known topics")
    func knownTopics() {
        let filter = GuestEventFilter.parse("stats,ports,apps.frontmost")
        #expect(filter.topics == ["stats", "ports", "apps.frontmost"])
    }

    @Test("drops unknown topics silently for forward-compat")
    func unknownTopicsDropped() {
        let filter = GuestEventFilter.parse("stats,future_topic,ports")
        #expect(filter.topics == ["stats", "ports"])
    }

    @Test("whitespace around topic names is tolerated")
    func whitespaceTolerant() {
        let filter = GuestEventFilter.parse("stats, ports ,apps.frontmost")
        #expect(filter.topics == ["stats", "ports", "apps.frontmost"])
    }

    @Test("allows() says yes for subscribed topics")
    func allowsChecks() {
        let statsOnly = GuestEventFilter.parse("stats")
        #expect(statsOnly.allows(topic: "stats") == true)
        #expect(statsOnly.allows(topic: "ports") == false)

        let everything = GuestEventFilter.all
        #expect(everything.allows(topic: "stats") == true)
        #expect(everything.allows(topic: "ports") == true)
        #expect(everything.allows(topic: "anything") == true)
    }
}
