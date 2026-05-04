import Foundation

// MARK: - API Response Types

/// The status of a VM as reported by the API.
///
/// Every VM resource in the API includes these fields. This struct is
/// the single source of truth for JSON serialization — both the CLI
/// `--json` output and the HTTP API share the same shape.
public struct VMStatus: Codable, Sendable, Equatable {

    public let name: String
    public let running: Bool
    public let cpu: Int
    public let memorySizeInGigabytes: UInt64
    public let diskSizeInGigabytes: UInt64
    public let displays: Int

    /// Network mode as a typed enum. Serializes as its raw string.
    public let network: NetworkMode

    public let audio: Bool
    public let microphone: Bool
    public let macAddress: String?
    public let setupCompleted: Bool

    /// Stable UUID assigned when the VM bundle was created.
    public let id: UUID

    /// When the VM bundle was created.
    public let createdAt: Date

    /// Absolute path to the VM bundle directory.
    public let path: String

    public init(
        name: String,
        running: Bool,
        cpu: Int,
        memorySizeInGigabytes: UInt64,
        diskSizeInGigabytes: UInt64,
        displays: Int,
        network: NetworkMode,
        audio: Bool,
        microphone: Bool,
        macAddress: String?,
        setupCompleted: Bool,
        id: UUID,
        createdAt: Date,
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

/// Actions a VM can be subject to via the lifecycle API.
public enum VMAction: String, Codable, Sendable, CaseIterable, Equatable {
    case start
    case stop
    case restart
    case clone
    case delete
    case snapshot
    case restore
}

/// Response for start/stop/clone/delete action requests.
public struct VMActionResponse: Codable, Sendable, Equatable {
    public let name: String
    public let action: VMAction
    public let pid: Int?
    public let log: String?

    public init(name: String, action: VMAction, pid: Int?, log: String?) {
        self.name = name
        self.action = action
        self.pid = pid
        self.log = log
    }
}

/// Response for delete actions.
public struct VMDeleteResponse: Codable, Sendable, Equatable {
    public let name: String
    public let deleted: Bool

    public init(name: String, deleted: Bool) {
        self.name = name
        self.deleted = deleted
    }
}

/// Response for IP resolution.
public struct VMIPResponse: Codable, Sendable, Equatable {
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
public struct HealthResponse: Codable, Sendable, Equatable {
    public let service: String
    public let version: String

    public init(service: String, version: String) {
        self.service = service
        self.version = version
    }
}

/// Response for VM list.
public struct VMListResponse: Codable, Sendable, Equatable {
    public let vms: [VMStatus]

    public init(vms: [VMStatus]) {
        self.vms = vms
    }
}
