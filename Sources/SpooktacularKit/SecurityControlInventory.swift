import Foundation

// MARK: - Security control inventory
//
// Hosted in SpooktacularKit (not the `spook` executable target)
// so tests can `@testable import SpooktacularKit` without hitting
// the executable-target symbol-export limitation. The CLI command
// that renders the inventory lives in `Sources/spook/Commands/
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
    public static let all: [SecurityControl] = [

        // MARK: Authentication & Identity

        SecurityControl(
            name: "mTLS with TLS 1.3 floor",
            category: "Authentication & Identity",
            standard: "NIST SP 800-52 Rev 2; OWASP ASVS V9.1",
            implementation: "Sources/SpookInfrastructureApple/KeychainTLSProvider.swift + HTTPAPIServer.init sec_protocol_options_set_min_tls_protocol_version",
            test: "Tests/SpooktacularKitTests/HTTPAPIIntegrationTests.swift",
            notes: "TLS 1.3 enforced server-side AND client-side; TLS cert hot-reload preserves the floor."
        ),
        SecurityControl(
            name: "OIDC JWT verification with strict algorithm pinning",
            category: "Authentication & Identity",
            standard: "OWASP JWT Cheat Sheet; NIST SP 800-131A (RSA 2048-bit minimum)",
            implementation: "Sources/SpookInfrastructureApple/OIDCTokenVerifier.swift",
            test: "Tests/SpooktacularKitTests/OIDCHardeningTests.swift",
            notes: "Only RS256 accepted; nbf/iat/exp/aud/iss validated with 60s skew; empty-modulus guard."
        ),
        SecurityControl(
            name: "JWKS pinning (static file or URL override)",
            category: "Authentication & Identity",
            standard: "OWASP ASVS V9.1.2 (pin endpoint trust)",
            implementation: "Sources/SpookCore/FederatedIdentity.swift (OIDCProviderConfig.staticJWKSPath / jwksURLOverride) + OIDCTokenVerifier.fetchJWKS three-tier resolver",
            test: "Tests/SpooktacularKitTests/OIDCHardeningTests.swift",
            notes: "Resolution: static file > URL override > discovery. Air-gapped deployments pin JWKS to disk."
        ),
        SecurityControl(
            name: "SAML 2.0 assertion verification with replay cache",
            category: "Authentication & Identity",
            standard: "OWASP SAML Cheat Sheet",
            implementation: "Sources/SpookInfrastructureApple/SAMLAssertionVerifier.swift + SAMLReplayCache",
            test: "Tests/SpooktacularKitTests/SAMLVerifierTests.swift",
            notes: "XMLParser with external entities disabled (XXE); XSW detection; assertion replay prevention."
        ),

        // MARK: Authorization

        SecurityControl(
            name: "RBAC with deny-by-default + runtime mutation API",
            category: "Authorization",
            standard: "OWASP ASVS V4.1; NIST SP 800-162 (ABAC)",
            implementation: "Sources/SpookCore/RBACModel.swift + Sources/SpookInfrastructureApple/JSONRoleStore.swift + HTTPAPIServer.handleRoleAPI",
            test: "Tests/SpooktacularKitTests/JSONRoleStorePersistenceTests.swift",
            notes: "Assignments persisted atomically to ~/.spooktacular/rbac.json by default (survives restart)."
        ),
        SecurityControl(
            name: "Multi-tenant isolation (no cross-tenant reuse / warm-pool leakage)",
            category: "Authorization",
            standard: "SOC 2 CC6.1",
            implementation: "Sources/SpookCore/TenancyModel.swift (MultiTenantIsolation.canReuse) + RunnerPoolReconciler",
            test: "Tests/SpooktacularKitTests/MultiTenantAuthTests.swift",
            notes: "Every request carries a TenantID; scheduler gates ensure tenant A can't schedule onto tenant B's host pools."
        ),
        SecurityControl(
            name: "Fair-share scheduler (weighted max-min)",
            category: "Authorization",
            standard: "Capacity fairness — no starvation",
            implementation: "Sources/SpookCore/FairScheduler.swift + RunnerPoolReconciler.fairShareAllocation",
            test: "Tests/SpooktacularKitTests/FairSchedulerTests.swift",
            notes: "Activated via SPOOK_SCHEDULER_POLICY + SPOOK_FLEET_CAPACITY. Deterministic, work-conserving, monotone."
        ),

        // MARK: Break-Glass

        SecurityControl(
            name: "Time-limited, single-use break-glass tickets",
            category: "Break-Glass",
            standard: "NIST SP 800-53 AC-14; OWASP ASVS V2.10; SOC 2 CC6.6; OWASP JWT Cheat Sheet",
            implementation: "Sources/SpookCore/BreakGlassTicket.swift + Sources/SpookInfrastructureApple/BreakGlassTicketCodec.swift + Sources/spooktacular-agent/BreakGlassVerification.swift",
            test: "Tests/SpooktacularKitTests/BreakGlassTicketTests.swift",
            notes: "Ed25519-signed, 1h TTL cap, JTI denylist. Four-gate server-side enforcement at the guest agent."
        ),
        SecurityControl(
            name: "Three-tier vsock channel isolation",
            category: "Break-Glass",
            standard: "Transport-layer capability segregation",
            implementation: "Sources/spooktacular-agent/AgentHTTPServer.swift listenAll + AgentRouter.endpointScope",
            test: "Tests/SpooktacularKitTests/GuestAgentContractTests.swift",
            notes: "Ports 9470 (read-only), 9471 (runner), 9472 (break-glass). Requests exceeding channel scope rejected at accept time."
        ),

        // MARK: Audit & Non-Repudiation

        SecurityControl(
            name: "Merkle-tree tamper-evident audit log (RFC 6962)",
            category: "Audit & Non-Repudiation",
            standard: "RFC 6962 / RFC 9162; NIST SP 800-53 AU-9",
            implementation: "Sources/SpookInfrastructureApple/HashChainAuditSink.swift",
            test: "Tests/SpooktacularKitTests/AuditPipelineTests.swift",
            notes: "Ed25519-signed tree heads over the §3.5 TBS structure (version + sig_type + ms timestamp + size + root)."
        ),
        SecurityControl(
            name: "Append-only audit file (UF_APPEND kernel-enforced)",
            category: "Audit & Non-Repudiation",
            standard: "NIST SP 800-53 AU-9",
            implementation: "Sources/SpookInfrastructureApple/AppendOnlyFileAuditStore.swift",
            test: "Tests/SpooktacularKitTests/AuditPipelineTests.swift",
            notes: "BSD chflags UF_APPEND verified on init; kernel blocks overwrites even from root."
        ),
        SecurityControl(
            name: "S3 Object Lock WORM audit export",
            category: "Audit & Non-Repudiation",
            standard: "SOC 2 Type II",
            implementation: "Sources/SpookInfrastructureApple/S3ObjectLockAuditStore.swift (hand-rolled SigV4 via SigV4Signer)",
            test: "Tests/SpooktacularKitTests/AuditSinkTests.swift",
            notes: "Compliance-mode retention immune to root-account shortening. Auto-included in the sink chain when s3Bucket is configured."
        ),
        SecurityControl(
            name: "Production preflight refuses insecure startup",
            category: "Audit & Non-Repudiation",
            standard: "Fail-closed invariant",
            implementation: "Sources/SpookApplication/ProductionPreflight.swift",
            test: "Tests/SpooktacularKitTests/ProductionPreflightTests.swift",
            notes: "Refuses to start without audit sink (any tenancy mode) or without RBAC + mTLS in multi-tenant."
        ),

        // MARK: Data at Rest

        SecurityControl(
            name: "CUFUA VM bundle protection with inheritance",
            category: "Data at Rest",
            standard: "OWASP ASVS V6.1.1 / V6.4.1 / V14.2.6",
            implementation: "Sources/SpookInfrastructureApple/BundleProtection.swift + VirtualMachineBundle.create + CloneManager + SnapshotManager",
            test: "Tests/SpooktacularKitTests/BundleProtectionInheritanceTests.swift",
            notes: "Applied on portable Macs (IOKit battery detect); override via SPOOK_BUNDLE_PROTECTION or GUI Settings → Security."
        ),
        SecurityControl(
            name: "Keychain-backed secret storage",
            category: "Data at Rest",
            standard: "OWASP ASVS V6.4; Apple Keychain Services",
            implementation: "Sources/SpookInfrastructureApple/KeychainTLSProvider.swift + Sources/SpooktacularKit/GitHubTokenResolution.swift",
            test: "Tests/SpooktacularKitTests/GitHubTokenResolutionTests.swift",
            notes: "API tokens, TLS private keys, GitHub PATs. kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly enforced."
        ),
        SecurityControl(
            name: "Atomic 0600 signing-key creation (no TOCTOU)",
            category: "Data at Rest",
            standard: "CWE-362 mitigation",
            implementation: "Sources/SpookInfrastructureApple/AuditSinkFactory.swift (loadOrCreateSigningKey — open(2) O_CREAT|O_EXCL|O_NOFOLLOW, 0600)",
            test: "Tests/SpooktacularKitTests/EnterpriseReadinessTests.swift",
            notes: "Closes the umask-default TOCTOU window the prior Data.write + chmod sequence had."
        ),

        // MARK: Cross-Region Coordination

        SecurityControl(
            name: "Cross-region distributed lock (DynamoDB Global Tables)",
            category: "Cross-Region Coordination",
            standard: "Strong consistency for global fleets",
            implementation: "Sources/SpookInfrastructureApple/DynamoDBDistributedLock.swift + DistributedLockFactory",
            test: "Tests/SpooktacularKitTests/EnterpriseReadinessTests.swift",
            notes: "Selected via SPOOK_DYNAMO_TABLE; K8s Lease and file-lock alternatives via same factory."
        ),

        // MARK: Injection & Path Safety

        SecurityControl(
            name: "Command-injection hardening on SSH exec path",
            category: "Injection & Path Safety",
            standard: "CWE-78 mitigation",
            implementation: "Sources/spook/Commands/Exec.swift (posixShellEscape)",
            test: nil,
            notes: "Every command token POSIX-escaped before joining for SSH transmission."
        ),
        SecurityControl(
            name: "Path-traversal hardening on guest-agent /fs",
            category: "Injection & Path Safety",
            standard: "CWE-22 mitigation",
            implementation: "Sources/spooktacular-agent/AgentRouter.swift handleListFS (component-aware containment + symmetric symlink resolution)",
            test: "Tests/SpooktacularKitTests/GuestAgentContractTests.swift",
            notes: "Sibling directory prefix bypass closed (e.g. /Users/administrator no longer escapes /Users/admin allow-list)."
        ),
        SecurityControl(
            name: "VM name regex validation everywhere",
            category: "Injection & Path Safety",
            standard: "OWASP input validation",
            implementation: "Sources/SpookInfrastructureApple/SpooktacularPaths.swift (vmNamePattern, validateVMName)",
            test: "Tests/SpooktacularKitTests/VMBundleTests.swift",
            notes: "^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$ applied at CLI + HTTP API + controller."
        ),

        // MARK: Supply Chain

        SecurityControl(
            name: "HTTP security headers per OWASP ASVS V14.4",
            category: "Supply Chain",
            standard: "OWASP ASVS V14.4.2–V14.4.7",
            implementation: "Sources/SpookInfrastructureApple/HTTPResponse.swift (serialize — X-Content-Type-Options, CSP, HSTS, X-Frame-Options, Referrer-Policy, Cache-Control)",
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
