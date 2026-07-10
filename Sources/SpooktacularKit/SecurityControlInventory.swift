import Foundation

// MARK: - Security control inventory
//
// Hosted in SpooktacularKit (not the `spook` executable target)
// so tests can `@testable import SpooktacularKit` without hitting
// the executable-target symbol-export limitation. The CLI command
// that renders the inventory lives in `Sources/spooktacular-cli/Commands/
// SecurityControls.swift` and consumes the types declared here.
/// CLI executable — so the same data powers the CLI, a future
/// DocC tutorial, and any SIEM exporter the compliance team
/// writes. Adding a control is a one-line insertion into
/// ``SecurityControlInventory/all``.
public struct SecurityControl: Codable, Sendable, Equatable {
    public let name: String
    public let category: String
    public let standard: String
    public let implementation: String
    public let test: String?
    public let notes: String?

    public init(
        name: String,
        category: String,
        standard: String,
        implementation: String,
        test: String? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.category = category
        self.standard = standard
        self.implementation = implementation
        self.test = test
        self.notes = notes
    }
}

/// Manifest of every security control Spooktacular ships.
///
/// This list is curated by hand rather than auto-generated — the
/// reviewer's question is "does this control exist and where",
/// which is exactly the question a reviewer asks of the
/// inventory. An auto-generated list would include every
/// security-adjacent symbol in the codebase and drown the real
/// signal.
///
/// Order inside each category is alphabetical for stable output.
public enum SecurityControlInventory {
    /// Flat list of every shipped security control in the
    /// codebase, keyed for audit review. Each entry points at
    /// the implementation file and the test file proving the
    /// control's behavior — `spook security-controls` renders
    /// this list verbatim so auditors can spot-check the
    /// evidence chain.
    public static let all: [SecurityControl] = [

        // MARK: Authentication & Identity

        SecurityControl(
            name: "mTLS with TLS 1.3 floor",
            category: "Authentication & Identity",
            standard: "NIST SP 800-52 Rev 2; OWASP ASVS V9.1",
            implementation: "Sources/SpooktacularInfrastructureApple/KeychainTLSProvider.swift + HTTPAPIServer.init sec_protocol_options_set_min_tls_protocol_version",
            test: "Tests/SpooktacularKitTests/HTTPAPIIntegrationTests.swift",
            notes: "TLS 1.3 enforced server-side AND client-side; TLS cert hot-reload preserves the floor."
        ),
        SecurityControl(
            name: "Hardware-bound break-glass signing via Secure Enclave (AAL3)",
            category: "Authentication & Identity",
            standard: "OWASP ASVS V2.7.1; NIST SP 800-63B AAL3; FIPS 140-3 Level 2 (SEP)",
            implementation: "Sources/SpooktacularInfrastructureApple/P256KeyStore.swift (unified store; break-glass uses Service.breakGlass with presenceGated: true)",
            test: "Tests/SpooktacularKitTests/P256KeyStoreTests.swift",
            notes: "Keys generated inside the SEP; private bytes never leave the Secure Enclave. Each signing operation gated by Touch ID / Watch / passcode. Full kernel compromise still cannot exfiltrate the key."
        ),
        SecurityControl(
            name: "Per-action MFA: LocalAuthentication gate on admin CLI commands",
            category: "Authentication & Identity",
            standard: "OWASP ASVS V4.3.1 (Administrative Interface MFA)",
            implementation: "Sources/SpooktacularInfrastructureApple/AdminPresenceGate.swift + Sources/spooktacular-cli/Commands/RBAC.swift (Assign/Revoke)",
            test: "Tests/SpooktacularKitTests/AdminPresenceGateTests.swift",
            notes: "LAContext.deviceOwnerAuthentication; fails closed on headless hosts unless SPOOKTACULAR_ADMIN_PRESENCE_BYPASS=1 is set (every bypass logged to OSLog at .error)."
        ),
        SecurityControl(
            name: "Workload-identity OIDC federation (ES256 JWT issuer, SEP-bound)",
            category: "Authentication & Identity",
            standard: "OpenID Connect Core 1.0; AWS STS AssumeRoleWithWebIdentity (ECDSA support announced 2024-11-22); RFC 7518 §3.4 (ES256)",
            implementation: "Sources/SpooktacularApplication/WorkloadTokenIssuer.swift + Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift",
            test: "Tests/SpooktacularKitTests/WorkloadTokenIssuerTests.swift",
            notes: "Spooktacular can federate directly with AWS STS. Signing key is SEP-bound; VMs get short-lived IAM credentials via AssumeRoleWithWebIdentity with no long-lived secrets. The most common ES256 JWT bug (DER vs raw signature) is pinned by test."
        ),
        SecurityControl(
            name: "Per-request signed operator-to-API auth",
            category: "Authentication & Identity",
            standard: "OWASP ASVS V2.10 (no unchanging service credentials); OWASP API Top 10 2023 A02 (broken authentication)",
            implementation: "Sources/SpooktacularApplication/SignedRequestVerifier.swift (P-256 ECDSA, nonce replay cache, ±60s skew, canonical-string body-hash binding) + Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift (operator-to-control-plane auth)",
            test: "Tests/SpooktacularKitTests/SignedRequestVerifierTests.swift",
            notes: "Operator-to-API requests signed with P-256 ECDSA. Trust allowlist via SPOOKTACULAR_API_PUBLIC_KEYS_DIR. No shared static tokens."
        ),
        // MARK: Authorization

        SecurityControl(
            name: "RBAC with deny-by-default + runtime mutation API",
            category: "Authorization",
            standard: "OWASP ASVS V4.1; NIST SP 800-162 (ABAC)",
            implementation: "Sources/SpooktacularCore/RBACModel.swift + Sources/SpooktacularInfrastructureApple/JSONRoleStore.swift + HTTPAPIServer.handleRoleAPI",
            test: "Tests/SpooktacularKitTests/JSONRoleStorePersistenceTests.swift",
            notes: "Assignments persisted atomically to ~/.spooktacular/rbac.json by default (survives restart)."
        ),
        SecurityControl(
            name: "Multi-tenant isolation (no cross-tenant reuse / warm-pool leakage)",
            category: "Authorization",
            standard: "SOC 2 CC6.1",
            implementation: "Sources/SpooktacularCore/TenancyModel.swift (MultiTenantIsolation.canReuse)",
            test: "Tests/SpooktacularKitTests/MultiTenantAuthTests.swift",
            notes: "Every request carries a TenantID; scheduler gates ensure tenant A can't schedule onto tenant B's host pools."
        ),
        // MARK: Audit & Non-Repudiation

        SecurityControl(
            name: "Append-only audit file (UF_APPEND kernel-enforced)",
            category: "Audit & Non-Repudiation",
            standard: "NIST SP 800-53 AU-9",
            implementation: "Sources/SpooktacularInfrastructureApple/AppendOnlyFileAuditStore.swift",
            test: "Tests/SpooktacularKitTests/AuditPipelineTests.swift",
            notes: "BSD chflags UF_APPEND verified on init; kernel blocks overwrites even from root."
        ),
        SecurityControl(
            name: "Production preflight refuses insecure startup",
            category: "Audit & Non-Repudiation",
            standard: "Fail-closed invariant",
            implementation: "Sources/SpooktacularApplication/ProductionPreflight.swift",
            test: "Tests/SpooktacularKitTests/ProductionPreflightTests.swift",
            notes: "Refuses to start without audit sink (any tenancy mode) or without RBAC + mTLS in multi-tenant."
        ),

        // MARK: Data at Rest

        SecurityControl(
            name: "CUFUA VM bundle protection with inheritance",
            category: "Data at Rest",
            standard: "OWASP ASVS V6.1.1 / V6.4.1 / V14.2.6",
            implementation: "Sources/SpooktacularInfrastructureApple/BundleProtection.swift + VirtualMachineBundle.create + CloneManager + SnapshotManager",
            test: "Tests/SpooktacularKitTests/BundleProtectionInheritanceTests.swift",
            notes: "Applied on portable Macs (IOKit battery detect); override via SPOOKTACULAR_BUNDLE_PROTECTION or GUI Settings → Security."
        ),
        SecurityControl(
            name: "Keychain-backed secret storage",
            category: "Data at Rest",
            standard: "OWASP ASVS V6.4; Apple Keychain Services",
            implementation: "Sources/SpooktacularInfrastructureApple/KeychainTLSProvider.swift + Sources/SpooktacularKit/GitHubTokenResolution.swift",
            test: "Tests/SpooktacularKitTests/GitHubTokenResolutionTests.swift",
            notes: "API tokens, TLS private keys, GitHub PATs. kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly enforced."
        ),
        SecurityControl(
            name: "VM → IAM role binding (workload identity federation)",
            category: "Authentication & Identity",
            standard: "OpenID Connect Core 1.0; AWS STS AssumeRoleWithWebIdentity; OWASP ASVS V2.10 (no unchanging credentials)",
            implementation: "Sources/SpooktacularCore/VMIAMBinding.swift + Sources/SpooktacularInfrastructureApple/JSONVMIAMBindingStore.swift + Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift (/v1/iam, /v1/vms/:name/identity-token) + Sources/spooktacular-cli/Commands/IAM.swift",
            test: "Tests/SpooktacularKitTests/VMIAMBindingTests.swift",
            notes: "Operators bind a VM to a cloud IAM role; the host mints short-lived ES256 JWTs via the SEP-bound WorkloadTokenIssuer; VMs get temporary cloud credentials via standard OIDC federation. No long-lived access keys in VM images."
        ),
        SecurityControl(
            name: "Tenant quota enforcement on VM create / clone",
            category: "Authorization",
            standard: "SOC 2 CC6.1 (logical access) + resource fairness",
            implementation: "Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift (evaluateTenantQuota) + Sources/SpooktacularCore/TenantQuota.swift",
            test: "Tests/SpooktacularKitTests/TenantQuotaTests.swift",
            notes: "Counts active VMs per tenant at create / clone time; returns 403 with denial reason when the quota is exceeded. Per-server scoping; distributed counter is a follow-up for multi-instance deployments."
        ),
        SecurityControl(
            name: "OpenTelemetry trace exporter (OTLP-HTTP-JSON)",
            category: "Observability",
            standard: "OpenTelemetry Protocol (OTLP) — opentelemetry.io/docs/specs/otlp",
            implementation: "Sources/SpooktacularApplication/OTLPExporter.swift + Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift (span emission on every request)",
            test: "Tests/SpooktacularKitTests/OTLPExporterTests.swift",
            notes: "Spooktacular emits a server-kind span per API request with method / path-template / status / tenant attributes. Works with Tempo, Honeycomb, Datadog APM, AWS X-Ray (via ADOT Collector). Best-effort export — collector stalls never back up the API path."
        ),
        SecurityControl(
            name: "SEP-only signing keys — no software-key fallback",
            category: "Data at Rest",
            standard: "Threat: malware running as the logged-in user",
            implementation: "Sources/SpooktacularInfrastructureApple/P256KeyStore.swift (loadOrCreateSEP as the sole provisioning path). The previous `loadOrCreateSoftware` helper, along with `SPOOKTACULAR_AUDIT_SIGNING_KEY_PATH` and `SPOOKTACULAR_OIDC_ISSUER_KEY_PATH`, no longer exist.",
            test: "Tests/SpooktacularKitTests/P256KeyStoreTests.swift",
            notes: "PEM-on-disk keys are reachable by any process with the logged-in user's UID; SEP-bound keys are hardware-isolated and non-extractable even under full kernel compromise. The daemon resolves keys by Keychain label and fails at startup if the label is missing — silent ephemeral keys are not possible."
        ),

        // MARK: Injection & Path Safety

        SecurityControl(
            name: "Command-injection hardening on SSH exec path",
            category: "Injection & Path Safety",
            standard: "CWE-78 mitigation",
            implementation: "Sources/spooktacular-cli/Commands/Exec.swift (posixShellEscape)",
            test: nil,
            notes: "Every command token POSIX-escaped before joining for SSH transmission."
        ),
        SecurityControl(
            name: "VM display-name validation (control chars + path separators rejected)",
            category: "Injection & Path Safety",
            standard: "OWASP input validation",
            implementation: "Sources/SpooktacularInfrastructureApple/SpooktacularPaths.swift (validateDisplayName, isValidDisplayName)",
            test: "Tests/SpooktacularKitTests/VMBundleTests.swift",
            notes: "1–128 Unicode characters after trimming, no ASCII control characters, no forward or backward slashes; applied at CLI (Create, Clone) + HTTP API (HTTPAPIServer). Deliberately looser than the pre-UUID-keying regex: bundle directories are now named by the VM's stable UUID, so the display name is presentation-only and no longer a filesystem path component."
        ),

        // MARK: Supply Chain

        SecurityControl(
            name: "HTTP security headers per OWASP ASVS V14.4",
            category: "Supply Chain",
            standard: "OWASP ASVS V14.4.2–V14.4.7",
            implementation: "Sources/SpooktacularInfrastructureApple/HTTPResponse.swift (serialize — X-Content-Type-Options, CSP, HSTS, X-Frame-Options, Referrer-Policy, Cache-Control)",
            test: "Tests/SpooktacularKitTests/HTTPSecurityHeadersTests.swift",
            notes: "Applied to every response regardless of status. CSP default-src 'none' is correct for a JSON-only API."
        ),
        SecurityControl(
            name: "Hardened Runtime + codesign timestamp",
            category: "Supply Chain",
            standard: "Apple notarization + RFC 3161",
            implementation: "build-app.sh (codesign --options runtime --timestamp)",
            test: nil,
            notes: "Ad-hoc builds skip timestamp since Apple's TSA won't sign unsigned objects."
        ),
        SecurityControl(
            name: "Zero third-party Swift dependencies",
            category: "Supply Chain",
            standard: "Minimize attack surface",
            implementation: "Package.swift (no `.package(url:)` entries)",
            test: "Tests/SpooktacularKitTests/DocConsistencyTests.swift",
            notes: "Verified by CI; every security primitive comes from Apple SDKs (CryptoKit, Security, Network)."
        ),
    ]
}
