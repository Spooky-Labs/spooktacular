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

    /// Maximum token TTL in seconds. Capped at 3600 (1h) — AWS
    /// STS `sts:AssumeRoleWithWebIdentity` has its own duration
    /// policy on the role, so this is primarily about limiting
    /// how long a leaked JWT is replayable.
    public let maxTTLSeconds: Int

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
    ) {
        self.vmName = vmName
        self.tenant = tenant
        self.roleArn = roleArn
        self.audience = audience
        self.maxTTLSeconds = min(max(maxTTLSeconds, 60), 3600)
        self.additionalClaims = additionalClaims
        self.createdAt = createdAt
        self.createdBy = createdBy
    }

    /// Composite key for store lookup: tenant + VM name, joined.
    /// Unique per tenant — a VM name is unique only within its
    /// tenant scope.
    public var storeKey: String { "\(tenant.rawValue)/\(vmName)" }
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
