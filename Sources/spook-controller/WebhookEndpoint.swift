import Foundation
import os
import SpookCore
import SpookApplication
import SpookInfrastructureApple

/// HTTP endpoints exposed by the Spooktacular controller.
///
/// Two kinds of webhooks live here, intentionally grouped so they
/// share the same request-parsing primitives:
///
/// 1. **GitHub `workflow_job` webhooks** — drive runner state-machine
///    transitions. Verified via HMAC-SHA-256 using
///    ``WebhookSignatureVerifier``.
/// 2. **Kubernetes admission webhooks** — validate CREATE / UPDATE
///    for `MacOSVM` and `RunnerPool` CRDs before they are persisted.
///    TLS is terminated by the cluster-facing Service; authentication
///    is implicit in the API server's mTLS handshake.
enum WebhookEndpoint {

    private static let logger = Logger(subsystem: "com.spooktacular.controller", category: "webhook")

    /// Handles an incoming GitHub workflow_job webhook.
    ///
    /// After verifying the HMAC signature and parsing the payload, dispatches
    /// `workflow_job` events to the ``RunnerPoolReconciler`` so that the
    /// matching runner's ``RunnerStateMachine`` receives `.jobStarted` or
    /// `.jobCompleted`.
    ///
    /// - Parameters:
    ///   - body: Raw HTTP request body.
    ///   - headers: HTTP headers (case-insensitive lookup).
    ///   - secret: The webhook HMAC secret.
    ///   - reconciler: The pool reconciler to dispatch events to.
    /// - Returns: HTTP status code to return to GitHub.
    static func handle(
        body: Data,
        headers: [String: String],
        secret: String,
        reconciler: RunnerPoolReconciler? = nil
    ) async -> Int {
        // 1. Verify signature
        let signature = headers["x-hub-signature-256"]
            ?? headers["X-Hub-Signature-256"] ?? ""
        guard WebhookSignatureVerifier.verify(body: body, signature: signature, secret: secret, hmac: CryptoKitHMACProvider()) else {
            logger.warning("Webhook signature verification failed")
            return 401
        }

        // 2. Filter event type
        let eventType = headers["x-github-event"]
            ?? headers["X-GitHub-Event"] ?? ""
        guard eventType == "workflow_job" else {
            logger.debug("Ignoring webhook event type: \(eventType, privacy: .public)")
            return 200
        }

        // 3. Parse payload
        guard let event = try? JSONDecoder().decode(WorkflowJobWebhook.self, from: body) else {
            logger.error("Failed to parse workflow_job webhook payload")
            return 400
        }

        logger.info("Webhook: workflow_job.\(String(describing: event.action), privacy: .public) runner=\(event.workflowJob.runnerName ?? "nil", privacy: .public)")

        // 4. Dispatch to RunnerPoolReconciler.
        //    Only in_progress and completed actions map to state machine events;
        //    the reconciler handles the filtering internally.
        if let reconciler {
            await reconciler.dispatchWebhook(event)
        }

        return 200
    }

    // MARK: - Admission Webhook

    /// Validates a `MacOSVM` or `RunnerPool` admission request.
    ///
    /// The Kubernetes API server posts an `AdmissionReview` object at
    /// `POST /admission/validate`; the webhook returns an
    /// `AdmissionResponse` with `allowed` and an optional human-readable
    /// message. A fail-closed `failurePolicy: Fail` on the
    /// `ValidatingWebhookConfiguration` means any error (non-200, bad
    /// JSON) rejects the request.
    ///
    /// Enforced invariants:
    /// - `MacOSVM.spec.tenant` must match the enclosing namespace's
    ///   `spooktacular.app/tenant` label. Prevents a tenant-A namespace
    ///   from forging a MacOSVM labeled for tenant-B.
    /// - `MacOSVM` creation is denied when the target node has already
    ///   reached the 2-VM-per-host limit enforced by Apple's kernel.
    /// - `RunnerPool.spec.sourceVM` must be present in the tenant's
    ///   image allowlist (derived from the namespace's
    ///   `spooktacular.app/image-allowlist` annotation as a comma-
    ///   separated list). If the annotation is absent, any image is
    ///   allowed (behaves like a permissive default for single-tenant
    ///   deployments).
    ///
    /// - Parameters:
    ///   - body: Raw request body containing the `AdmissionReview`.
    ///   - namespaceResolver: Async closure returning `NamespaceMetadata`
    ///     for a given namespace name. Injected so tests can stub.
    ///   - nodeVMCount: Closure returning the MacOSVM count on a node;
    ///     injected so tests can stub.
    /// - Returns: A tuple of `(statusCode, body)` suitable for the
    ///   admission webhook HTTP response.
    static func admit(
        body: Data,
        namespaceResolver: @Sendable (String) async -> NamespaceMetadata?,
        nodeVMCount: @Sendable (String) async -> Int
    ) async -> (Int, Data) {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        guard let review = try? decoder.decode(AdmissionReview.self, from: body),
              let request = review.request else {
            logger.error("Admission: failed to decode AdmissionReview or missing request")
            return (400, Data())
        }
        var allowed = true
        var denyReason: String?

        // MacOSVM validation
        if request.kind.kind == "MacOSVM" {
            if let raw = request.object,
               let vm = try? decoder.decode(MacOSVM.self, from: raw) {
                let nsMeta = await namespaceResolver(request.namespace ?? "default")

                // 1. Tenant alignment: spec.tenant must match namespace tenant.
                if let specTenant = vm.spec.tenant, !specTenant.isEmpty,
                   let nsTenant = nsMeta?.labels["spooktacular.app/tenant"],
                   specTenant != nsTenant {
                    allowed = false
                    denyReason = "MacOSVM spec.tenant='\(specTenant)' does not match namespace tenant='\(nsTenant)'"
                }

                // 2. 2-VM-per-host capacity.
                if allowed, request.operation == "CREATE" {
                    let nodeName = vm.spec.nodeName
                    let existing = await nodeVMCount(nodeName)
                    if existing >= Self.macVMPerHostLimit {
                        allowed = false
                        denyReason = "Node '\(nodeName)' is at the 2-VM-per-host limit (Apple kernel); found \(existing) active MacOSVMs"
                    }
                }
            }
        }

        // RunnerPool validation
        if request.kind.kind == "RunnerPool" {
            if let raw = request.object,
               let pool = try? decoder.decode(RunnerPool.self, from: raw) {
                let nsMeta = await namespaceResolver(request.namespace ?? "default")

                // Image allowlist: namespace may carry a
                // `spooktacular.app/image-allowlist` annotation with a
                // comma-separated list of allowed sourceVM names.
                if let allowlistRaw = nsMeta?.annotations["spooktacular.app/image-allowlist"],
                   !allowlistRaw.isEmpty {
                    let allowed_images = allowlistRaw
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                    if !allowed_images.contains(pool.spec.sourceVM) {
                        allowed = false
                        denyReason = "RunnerPool.spec.sourceVM='\(pool.spec.sourceVM)' is not in namespace image allowlist (\(allowed_images.joined(separator: ", ")))"
                    }
                }

                // Tenant label alignment: if the pool carries a tenant
                // label, it must match the namespace's tenant label.
                if allowed,
                   let poolTenant = pool.metadata.labels?["spooktacular.app/tenant"],
                   let nsTenant = nsMeta?.labels["spooktacular.app/tenant"],
                   poolTenant != nsTenant {
                    allowed = false
                    denyReason = "RunnerPool tenant label='\(poolTenant)' does not match namespace tenant='\(nsTenant)'"
                }
            }
        }

        let response = AdmissionResponse(
            uid: request.uid,
            allowed: allowed,
            status: denyReason.map { AdmissionStatus(code: 403, message: $0) }
        )
        let reviewResponse = AdmissionReview(
            apiVersion: review.apiVersion,
            kind: review.kind,
            request: nil,
            response: response
        )

        if !allowed, let reason = denyReason {
            logger.warning("Admission denied: \(reason, privacy: .public)")
        } else {
            logger.info("Admission allowed: \(request.kind.kind, privacy: .public)/\(request.name ?? "?", privacy: .public)")
        }

        do {
            let data = try encoder.encode(reviewResponse)
            return (200, data)
        } catch {
            logger.error("Admission: failed to encode response: \(error.localizedDescription, privacy: .public)")
            return (500, Data())
        }
    }

    /// Kernel-enforced per-host VM cap on Apple Silicon. The admission
    /// webhook rejects CREATEs that would exceed this limit so operators
    /// see a clean 403 instead of a boot-time failure on the Mac host.
    static let macVMPerHostLimit = 2
}

// MARK: - Admission Types

/// A namespace's labels and annotations, resolved by the admission
/// webhook to enforce tenant isolation.
struct NamespaceMetadata: Sendable {
    let name: String
    let labels: [String: String]
    let annotations: [String: String]
}

/// Top-level `AdmissionReview` object as defined by
/// `admission.k8s.io/v1`.
///
/// Both request and response share this envelope. Inbound payloads
/// from the API server carry ``request`` and omit ``response``;
/// outbound webhook answers carry ``response`` and omit ``request``.
///
/// See <https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>.
struct AdmissionReview: Codable, Sendable {
    let apiVersion: String
    let kind: String
    let request: AdmissionRequest?
    let response: AdmissionResponse?
}

/// The inbound admission request from the K8s API server.
struct AdmissionRequest: Codable, Sendable {
    let uid: String
    let kind: GroupVersionKind
    let resource: GroupVersionResource?
    let name: String?
    let namespace: String?
    let operation: String
    let object: Data?
    let oldObject: Data?

    private enum CodingKeys: String, CodingKey {
        case uid, kind, resource, name, namespace, operation, object, oldObject
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.uid = try container.decode(String.self, forKey: .uid)
        self.kind = try container.decode(GroupVersionKind.self, forKey: .kind)
        self.resource = try container.decodeIfPresent(GroupVersionResource.self, forKey: .resource)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.namespace = try container.decodeIfPresent(String.self, forKey: .namespace)
        self.operation = try container.decode(String.self, forKey: .operation)
        // `object` and `oldObject` are arbitrary JSON; re-serialise so
        // callers can decode them to concrete types.
        if let obj = try container.decodeIfPresent(AnyCodable.self, forKey: .object) {
            self.object = try JSONSerialization.data(withJSONObject: obj.value)
        } else {
            self.object = nil
        }
        if let obj = try container.decodeIfPresent(AnyCodable.self, forKey: .oldObject) {
            self.oldObject = try JSONSerialization.data(withJSONObject: obj.value)
        } else {
            self.oldObject = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(resource, forKey: .resource)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(namespace, forKey: .namespace)
        try container.encode(operation, forKey: .operation)
        if let object,
           let json = try? JSONSerialization.jsonObject(with: object) {
            try container.encode(AnyCodable(json), forKey: .object)
        }
        if let oldObject,
           let json = try? JSONSerialization.jsonObject(with: oldObject) {
            try container.encode(AnyCodable(json), forKey: .oldObject)
        }
    }
}

/// Kubernetes `meta/v1.GroupVersionKind`.
struct GroupVersionKind: Codable, Sendable, Equatable {
    let group: String
    let version: String
    let kind: String
}

/// Kubernetes `meta/v1.GroupVersionResource`.
struct GroupVersionResource: Codable, Sendable, Equatable {
    let group: String
    let version: String
    let resource: String
}

/// The admission response written back to the K8s API server.
struct AdmissionResponse: Codable, Sendable {
    let uid: String
    let allowed: Bool
    let status: AdmissionStatus?
}

/// Human-readable status attached to a denial.
struct AdmissionStatus: Codable, Sendable {
    let code: Int
    let message: String
}

/// Type-erased JSON value. Used by ``AdmissionRequest`` so arbitrary
/// CRD payloads can flow through the admission review without the
/// controller pinning concrete schemas up front.
///
/// Not `Sendable` — it holds `Any`. ``AdmissionRequest`` materialises
/// payloads into `Data` before crossing concurrency boundaries, so
/// the lack of Sendable on this helper is intentional.
private struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(Bool.self) { value = v; return }
        if let v = try? container.decode(Int64.self) { value = v; return }
        if let v = try? container.decode(Double.self) { value = v; return }
        if let v = try? container.decode(String.self) { value = v; return }
        if let v = try? container.decode([AnyCodable].self) {
            value = v.map { $0.value }; return
        }
        if let v = try? container.decode([String: AnyCodable].self) {
            value = v.mapValues { $0.value }; return
        }
        if container.decodeNil() { value = NSNull(); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unsupported JSON value"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Int64: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        case let v as [Any]: try container.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try container.encode(v.mapValues(AnyCodable.init))
        case is NSNull: try container.encodeNil()
        default:
            try container.encodeNil()
        }
    }
}
