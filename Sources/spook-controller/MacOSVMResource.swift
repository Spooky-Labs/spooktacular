/// Codable types for the MacOSVM custom resource definition.
///
/// CRD group: `spooktacular.app`, version: `v1alpha1`, resource: `macosvms`.

import Foundation

// MARK: - Watch Event

/// A Kubernetes watch event from the streaming watch endpoint.
struct WatchEvent: Decodable, Sendable {
    let type: String
    let object: MacOSVM
}

// MARK: - MacOSVM

/// A MacOSVM custom resource as stored in the Kubernetes API.
struct MacOSVM: Codable, Sendable {
    let apiVersion: String
    let kind: String
    let metadata: ObjectMeta
    var spec: MacOSVMSpec
    var status: MacOSVMStatus?
}

// MARK: - ObjectMeta

/// Minimal Kubernetes ObjectMeta fields needed by the controller.
struct ObjectMeta: Codable, Sendable {
    let name: String
    let namespace: String?
    let uid: String?
    let resourceVersion: String?
    let deletionTimestamp: String?
}

// MARK: - MacOSVMSpec

/// The desired state of a MacOSVM.
struct MacOSVMSpec: Codable, Sendable {
    let baseImage: String
    let nodeName: String
    let cpu: Int?
    let memoryGB: Int?
    let diskGB: Int?
}

// MARK: - MacOSVMStatus

/// The observed state of a MacOSVM, written by the controller.
struct MacOSVMStatus: Codable, Sendable {
    var phase: Phase
    var ip: String?
    var nodeName: String?
    var message: String?

    enum Phase: String, Codable, Sendable {
        case pending = "Pending"
        case cloning = "Cloning"
        case starting = "Starting"
        case running = "Running"
        case stopping = "Stopping"
        case failed = "Failed"
        case deleted = "Deleted"
    }
}

// MARK: - MacOSVM List

/// Response from listing MacOSVM resources.
struct MacOSVMList: Decodable, Sendable {
    let apiVersion: String
    let kind: String
    let metadata: ListMeta
    let items: [MacOSVM]
}

/// List metadata with resourceVersion for watch resumption.
struct ListMeta: Decodable, Sendable {
    let resourceVersion: String?
}

// MARK: - Kubernetes Status

/// A Kubernetes API error or status response.
struct K8sStatus: Decodable, Sendable {
    let kind: String?
    let status: String?
    let message: String?
    let code: Int?
}
