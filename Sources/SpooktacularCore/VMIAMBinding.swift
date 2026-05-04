import Foundation

/// An operator-configured binding between a Spooktacular VM and a
/// cloud IAM role the workload inside that VM is authorized to
/// assume.
///
/// ## Why this exists
///
/// Operators want to say "VM `ci-runner-01` in tenant `team-a`
/// can assume role `arn:aws:iam::ACCT:role/ci-runner-builds`,
/// with session duration ≤ 1h, optionally carrying these custom
/// claims". At token-mint time the controller looks up the
/// binding for the requesting VM, constructs a
/// `WorkloadTokenIssuer` JWT with the bound `roleArn` + claim
/// overrides, and returns it. The VM's workload uses the JWT
/// with AWS `sts:AssumeRoleWithWebIdentity` (or GCP / Azure
/// equivalents) to mint short-lived cloud credentials scoped
/// to that role.
///
/// Binding is stored alongside tenancy config so RBAC decisions
/// for binding mutations compose with the existing tenant-scoped
/// permissions.
public struct VMIAMBinding: Sendable, Codable, Equatable {

    /// The VM this binding applies to, scoped by tenant.
    public let vmName: String
    public let tenant: TenantID

    /// The cloud IAM role ARN the workload assumes. Format is
    /// cloud-specific; validated at `attach` time against a
    /// loose regex only — the authoritative validation happens
    /// when AWS / GCP / Azure rejects a malformed or non-trusted
    /// role.
    public let roleArn: String

    /// Audience for the minted JWT's `aud` claim. The cloud
    /// provider's IAM trust policy must match this. Defaults to
    /// the standard AWS STS value `"sts.amazonaws.com"`.
    public let audience: String

    /// Maximum token TTL in seconds. Must be in
    /// ``VMIAMBinding/allowedTTLRange`` (60…3600). AWS STS
    /// `sts:AssumeRoleWithWebIdentity` has its own duration
    /// policy on the role; this cap limits how long a leaked
    /// JWT is replayable.
    public let maxTTLSeconds: Int

    /// Inclusive bounds on ``maxTTLSeconds``. A TTL outside
    /// this range causes ``init(vmName:tenant:roleArn:audience:maxTTLSeconds:additionalClaims:createdAt:createdBy:)``
    /// to throw ``IAMBindingError/ttlOutOfRange(requested:allowedMin:allowedMax:)``
    /// rather than silently clamping — silent clamping was the
    /// root cause of "I asked for 30s sessions, why are they
    /// lasting 60?" operator confusion, and the clamp could
    /// widen a caller's security posture without their
    /// knowledge.
    public static let allowedTTLRange: ClosedRange<Int> = 60...3600

    /// Custom claim overrides baked into every JWT minted for
    /// this binding. Useful for tenant-specific claim keys the
    /// role's trust policy keys off (e.g., `"environment":
    /// "prod"`).
    public let additionalClaims: [String: String]

    /// When this binding was created. Audit-only.
    public let createdAt: Date

    /// Operator identity that created the binding. Populated by
    /// the RBAC-aware `attach` path, not user-settable. Audit-
    /// only.
    public let createdBy: String

    public init(
        vmName: String,
        tenant: TenantID,
        roleArn: String,
        audience: String = "sts.amazonaws.com",
        maxTTLSeconds: Int = 900,
        additionalClaims: [String: String] = [:],
        createdAt: Date = Date(),
        createdBy: String
    ) throws {
        guard Self.allowedTTLRange.contains(maxTTLSeconds) else {
            throw IAMBindingError.ttlOutOfRange(
                requested: maxTTLSeconds,
                allowedMin: Self.allowedTTLRange.lowerBound,
                allowedMax: Self.allowedTTLRange.upperBound
            )
        }
        self.vmName = vmName
        self.tenant = tenant
        self.roleArn = roleArn
        self.audience = audience
        self.maxTTLSeconds = maxTTLSeconds
        self.additionalClaims = additionalClaims
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    /// Composite key for store lookup: tenant + VM name, joined.
    /// Unique per tenant — a VM name is unique only within its
    /// tenant scope.
    public var storeKey: String { "\(tenant.rawValue)/\(vmName)" }
}

// MARK: - Errors

/// Errors raised when constructing or mutating a ``VMIAMBinding``.
///
/// Kept distinct from transport / store errors so callers can
/// branch cleanly on model-level validation failures without
/// coupling to the persistence layer.
public enum IAMBindingError: Error, LocalizedError, Sendable, Equatable {

    /// ``VMIAMBinding/maxTTLSeconds`` was outside
    /// ``VMIAMBinding/allowedTTLRange``. Previously this was
    /// silently clamped — callers asking for 30s sessions got
    /// 60s, callers asking for 2h got 1h. Both directions
    /// change the security posture without informing the
    /// caller, so the API now rejects out-of-range values
    /// explicitly.
    case ttlOutOfRange(requested: Int, allowedMin: Int, allowedMax: Int)

    public var errorDescription: String? {
        switch self {
        case .ttlOutOfRange(let requested, let min, let max):
            "maxTTLSeconds \(requested) is out of the allowed range [\(min), \(max)]."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .ttlOutOfRange(_, let min, let max):
            "Choose a TTL in the range [\(min), \(max)] seconds. The lower bound prevents cold-start burn on the caller; the upper bound limits the replay window of a leaked JWT."
        }
    }
}

// MARK: - Role-ARN validation

/// Loose validation of cloud-provider role ARNs / URIs at
/// binding-creation time. The definitive rejection happens at
/// the STS / GCP / Azure layer; this is a fast-fail for typos.
public enum VMIAMBindingValidation {

    /// Returns `true` if `arn` matches one of the accepted
    /// cloud-provider patterns. The authoritative validator is
    /// always the cloud API — this is just a typo catcher.
    public static func isLikelyValidRoleARN(_ arn: String) -> Bool {
        // AWS: arn:aws:iam::123456789012:role/path/name
        // AWS GovCloud: arn:aws-us-gov:iam::...:role/...
        // AWS China: arn:aws-cn:iam::...:role/...
        if arn.hasPrefix("arn:aws:iam::")
            || arn.hasPrefix("arn:aws-us-gov:iam::")
            || arn.hasPrefix("arn:aws-cn:iam::") {
            return arn.contains(":role/")
        }
        // GCP: service-account email, e.g. sa@project.iam.gserviceaccount.com
        if arn.contains("@") && arn.hasSuffix(".iam.gserviceaccount.com") {
            return true
        }
        // Azure: subscription GUID path
        if arn.hasPrefix("/subscriptions/") && arn.contains("/providers/Microsoft.ManagedIdentity/") {
            return true
        }
        return false
    }
}
