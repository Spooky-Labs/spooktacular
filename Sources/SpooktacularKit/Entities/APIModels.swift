import Foundation

// MARK: - API Response Types

/// The status of a VM as reported by the API.
///
/// Every VM resource in the API includes these fields. This struct
/// is the single source of truth for JSON serialization -- both the
/// CLI `--json` output and the HTTP API share the same shape.
struct VMStatus: Codable, Sendable {
    let name: String
    let running: Bool
    let cpu: Int
    let memorySizeInGigabytes: UInt64
    let diskSizeInGigabytes: UInt64
    let displays: Int
    let network: String
    let audio: Bool
    let microphone: Bool
    let macAddress: String?
    let setupCompleted: Bool
    let id: String
    let createdAt: String
    let path: String
}

/// Response for start/stop actions.
struct VMActionResponse: Codable, Sendable {
    let name: String
    let action: String
    let pid: Int?
    let log: String?
}

/// Response for delete actions.
struct VMDeleteResponse: Codable, Sendable {
    let name: String
    let deleted: Bool
}

/// Response for IP resolution.
struct VMIPResponse: Codable, Sendable {
    let name: String
    let ip: String
    let mac: String
}

/// Response for health check.
struct HealthResponse: Codable, Sendable {
    let service: String
    let version: String
}

/// Response for VM list.
struct VMListResponse: Codable, Sendable {
    let vms: [VMStatus]
}
