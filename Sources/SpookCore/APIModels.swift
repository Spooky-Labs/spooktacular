import Foundation

// MARK: - API Response Types

/// The status of a VM as reported by the API.
///
/// Every VM resource in the API includes these fields. This struct
/// is the single source of truth for JSON serialization -- both the
/// CLI `--json` output and the HTTP API share the same shape.
public struct VMStatus: Codable, Sendable {
    public let name: String
    public let running: Bool
    public let cpu: Int
    public let memorySizeInGigabytes: UInt64
    public let diskSizeInGigabytes: UInt64
    public let displays: Int
    public let network: String
    public let audio: Bool
    public let microphone: Bool
    public let macAddress: String?
    public let setupCompleted: Bool
    public let id: String
    public let createdAt: String
    public let path: String

    public init(
        name: String,
        running: Bool,
        cpu: Int,
        memorySizeInGigabytes: UInt64,
        diskSizeInGigabytes: UInt64,
        displays: Int,
        network: String,
        audio: Bool,
        microphone: Bool,
        macAddress: String?,
        setupCompleted: Bool,
        id: String,
        createdAt: String,
        path: String
    ) {
        self.name = name
        self.running = running
        self.cpu = cpu
        self.memorySizeInGigabytes = memorySizeInGigabytes
        self.diskSizeInGigabytes = diskSizeInGigabytes
        self.displays = displays
        self.network = network
        self.audio = audio
        self.microphone = microphone
        self.macAddress = macAddress
        self.setupCompleted = setupCompleted
        self.id = id
        self.createdAt = createdAt
        self.path = path
    }
}

/// Response for start/stop actions.
public struct VMActionResponse: Codable, Sendable {
    public let name: String
    public let action: String
    public let pid: Int?
    public let log: String?

    public init(name: String, action: String, pid: Int?, log: String?) {
        self.name = name
        self.action = action
        self.pid = pid
        self.log = log
    }
}

/// Response for delete actions.
public struct VMDeleteResponse: Codable, Sendable {
    public let name: String
    public let deleted: Bool

    public init(name: String, deleted: Bool) {
        self.name = name
        self.deleted = deleted
    }
}

/// Response for IP resolution.
public struct VMIPResponse: Codable, Sendable {
    public let name: String
    public let ip: String
    public let mac: String

    public init(name: String, ip: String, mac: String) {
        self.name = name
        self.ip = ip
        self.mac = mac
    }
}

/// Response for health check.
public struct HealthResponse: Codable, Sendable {
    public let service: String
    public let version: String

    public init(service: String, version: String) {
        self.service = service
        self.version = version
    }
}

/// Response for VM list.
public struct VMListResponse: Codable, Sendable {
    public let vms: [VMStatus]

    public init(vms: [VMStatus]) {
        self.vms = vms
    }
}
