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
///
/// `generation` is incremented by the API server every time the spec
/// changes; controllers write ``MacOSVMStatus/observedGeneration``
/// equal to this value after successfully reconciling, so clients can
/// detect drift between desired and observed state.
struct ObjectMeta: Codable, Sendable {
    let name: String
    let namespace: String?
    let uid: String?
    let resourceVersion: String?
    let generation: Int64?
    let deletionTimestamp: String?
    var finalizers: [String]?
    var annotations: [String: String]?
    var labels: [String: String]?
}

// MARK: - MacOSVMSpec

/// The desired state of a MacOSVM.
struct MacOSVMSpec: Codable, Sendable {
    let baseImage: String
    let nodeName: String
    let cpu: Int?
    let memoryGB: Int?
    let diskGB: Int?
    /// Optional tenant label asserted in the spec. The admission
    /// webhook verifies this matches the enclosing namespace's
    /// `spooktacular.app/tenant` label.
    let tenant: String?
}

// MARK: - MacOSVMStatus

/// The observed state of a MacOSVM, written by the controller.
///
/// Follows the Kubernetes controller-runtime convention:
/// - ``observedGeneration`` tracks the most recent spec generation
///   that the controller has reconciled.
/// - ``conditions`` is a list of ``KubernetesCondition`` entries using
///   standard types (`Available`, `Progressing`, `Degraded`). Clients
///   prefer conditions over ``phase`` for programmatic checks.
struct MacOSVMStatus: Codable, Sendable {
    var phase: Phase
    var ip: String?
    var nodeName: String?
    var message: String?
    /// Spec generation that this status reflects. Written on every patch.
    var observedGeneration: Int64?
    /// Standard K8s conditions (Available / Progressing / Degraded).
    var conditions: [KubernetesCondition]?

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

// MARK: - Kubernetes Condition

/// A Kubernetes-style condition following the `meta/v1.Condition` shape.
///
/// Conventions mirror `k8s.io/apimachinery/pkg/apis/meta/v1/types.go`:
///
/// - ``type`` uses a short PascalCase identifier (e.g., `Available`).
/// - ``status`` is `"True" | "False" | "Unknown"`.
/// - ``lastTransitionTime`` is updated only when ``status`` changes.
/// - ``observedGeneration`` records the spec generation the condition
///   applies to.
///
/// See <https://pkg.go.dev/k8s.io/apimachinery/pkg/apis/meta/v1#Condition>.
struct KubernetesCondition: Codable, Sendable, Equatable {
    /// Condition type (short PascalCase).
    let type: String
    /// `"True" | "False" | "Unknown"`.
    let status: String
    /// Machine-readable cause (camelCase).
    let reason: String
    /// Human-readable detail.
    let message: String
    /// ISO 8601 timestamp of the last status change. Only updated
    /// when ``status`` changes so clients can reason about transition
    /// age.
    let lastTransitionTime: String
    /// The generation of the spec this condition applies to.
    let observedGeneration: Int64?

    /// Standard condition types used by the Spooktacular controller.
    ///
    /// - ``available``: The resource is fully functional (VM running, IP resolved).
    /// - ``progressing``: The controller is actively working toward the desired state.
    /// - ``degraded``: The resource is operating with reduced capability or failed.
    enum StandardType {
        static let available = "Available"
        static let progressing = "Progressing"
        static let degraded = "Degraded"
    }

    /// Standard condition status values.
    enum StandardStatus {
        static let `true` = "True"
        static let `false` = "False"
        static let unknown = "Unknown"
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
