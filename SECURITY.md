# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| N (current) | Yes   |
| N-1         | Yes   |
| < N-1       | No    |

We support the current release and the immediately prior release (N and N-1). Older versions do not receive security patches. Please update to a supported version before reporting a vulnerability.

## Security Model

Spooktacular supports two deployment classes: **Pilot (Single-Tenant)** and **Enterprise Platform (Multi-Tenant)**. See [Deployment Classes](#deployment-classes) for the full comparison. Single-tenant is the recommended starting point; multi-tenant adds tenant-partitioned scheduling, cross-tenant reuse prevention, and structured SIEM audit export.

In Pilot mode, the security model assumes the operator controls both the host and all guests. Production deployments require mandatory mTLS for controller-to-node traffic, Keychain-backed secret storage, and three-tier guest agent authorization.

### What this security model covers

- **Host ↔ Guest isolation**: VMs run in Apple's Virtualization.framework sandbox. The guest agent communicates over vsock (not the network), with host CID verification rejecting peer-to-peer connections.
- **Separate vsock channels per capability tier**: The guest agent binds three vsock ports, each enforcing a maximum scope at the transport layer before token authentication:
  - Port 9470: read-only (health, inspection, diagnostics)
  - Port 9471: runner control (mutation except exec)
  - Port 9472: break-glass (exec — disabled by default, requires explicit token)
  Requests exceeding the channel's scope are rejected with 403 at the socket accept layer.
- **HTTP API authentication**: The HTTP API requires TLS in production (`--tls-cert`/`--tls-key`) and per-request P-256 ECDSA signature verification via `SignedRequestVerifier`. Operators provision trusted caller public keys (one PEM per identity) in `SPOOK_API_PUBLIC_KEYS_DIR`; each request except `GET /health` carries `X-Spook-Timestamp`, `X-Spook-Nonce`, and `X-Spook-Signature` headers signed over a canonical string (`METHOD\npath\nsha256-hex(body)\ntimestamp\nnonce`). Replay-protected by a nonce cache with ±60s timestamp-skew tolerance. The static-Bearer-token path (`SPOOK_API_TOKEN`) was **retired**: shared secrets at rest on any client host are a liability that asymmetric signing with SEP-bound private keys eliminates structurally. Operators who need ad-hoc `curl` access use `spook sign-request` to produce the three headers. Production startup fails without TLS + a populated keys dir unless `--insecure` is explicitly set.
- **Three-tier guest agent authorization**: Read-only, runner, and break-glass token tiers. Shell execution (`/api/v1/exec`) requires a break-glass token and is only accessible on port 9472. Runner tokens get 403 on exec. Read-only tokens cannot mutate anything.
- **Mandatory mTLS in production**: The controller refuses to start without TLS certificates (`TLS_CERT_PATH`, `TLS_KEY_PATH`, `TLS_CA_PATH`). Both the controller and Mac nodes present certificates, preventing unauthorized API access even if a bearer token is compromised. Bearer tokens are retained as a secondary auth layer (defense in depth). The `SPOOK_INSECURE_CONTROLLER=1` bypass exists for local development only.
- **Keychain-based secret storage**: API tokens, runner registration tokens, and TLS private keys are stored in the macOS Keychain via `SecItemAdd`/`SecItemCopyMatching` rather than plaintext configuration files.
- **TLS certificate hot reload**: TLS certificates can be rotated without restarting the server. The server watches certificate files via `DispatchSource` and reloads them on change, enabling zero-downtime cert rotation.
- **Structured audit logging**: Every control-plane action produces an `AuditRecord` with: actor identity, tenant ID, authorization scope, resource, action, outcome, request ID, and ISO-8601 timestamp. Two concrete sinks:
  - `OSLogAuditSink`: writes to Apple's unified logging (`log show --predicate 'category == "audit"'`)
  - `JSONFileAuditSink`: appends JSONL to a file for SIEM ingestion (Splunk, Elasticsearch, CloudWatch Logs)
  
  JSONL schema per line:
  ```json
  {"id":"...","timestamp":"2026-04-15T...","actorIdentity":"spook-controller","tenant":"blue","scope":"runner","resource":"vm-001","action":"deleteVM","outcome":"success","correlationID":"req-123"}
  ```
- **VM name validation**: Regex-validated to prevent path traversal.
- **Capacity enforcement**: 2-VM limit with flock-serialized PID file writes to prevent TOCTOU races.
- **Code signing**: Hardened runtime, notarized for distribution, no `--deep` signing.
- **No telemetry**: Zero data collection, no network calls to our servers.

### What this security model does NOT cover

These are **known limitations**, not bugs:

- **Federated identity supports OIDC (JWT) and SAML 2.0**: OIDC uses JWKS-based RS256 signature verification with `nbf`, `exp`, `iat`, `aud`, and `iss` validation, 60s clock-skew tolerance, and a 2048-bit RSA minimum (NIST SP 800-131A). SAML 2.0 uses X.509 certificate-based XML signature verification via Security.framework with a `SAMLReplayCache` to reject assertion replays and signature-wrapping attacks (OWASP SAML Cheat Sheet). Group-to-scope and group-to-tenant mapping is configurable via `OIDCProviderConfig` and `SAMLProviderConfig`.
- **JWKS pinning for on-path attack resistance**: `OIDCProviderConfig` supports two pinning modes that bypass the default `/.well-known/openid-configuration` + `jwks_uri` fetch:
  - **`staticJWKSPath`** — load the provider's JWKS from an on-disk JSON document at verifier startup. Keys are at rest on the host, signed into config management, and rotate on the operator's schedule. The JWKS never touches the wire at verification time.
  - **`jwksURLOverride`** — skip discovery, fetch JWKS directly from a URL (e.g. an internal mirror fronted by the operator's own PKI), preserving runtime freshness while routing through a controlled trust store.
  The resolution order inside `OIDCTokenVerifier.fetchJWKS()` is **static file > URL override > discovery** (see `Sources/SpookInfrastructureApple/OIDCTokenVerifier.swift` and `Sources/SpookCore/FederatedIdentity.swift`). Missing / malformed static files fail closed with `OIDCError.staticJWKSUnreadable` — no silent fallback to network discovery.
- **Secure Enclave-backed audit signing key**: The Merkle audit signing key is persisted at `SPOOK_AUDIT_SIGNING_KEY` with mode 0600 created atomically via `open(2) O_CREAT | O_EXCL | O_NOFOLLOW`. On Apple Silicon the key can additionally be rotated into Secure-Enclave storage via the Keychain's `kSecAttrTokenIDSecureEnclave` policy; mTLS private keys loaded by `KeychainTLSProvider` are marked `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they never sync via iCloud Keychain. On CI hosts without a Secure Enclave the software-key path is still constant-time and never writes the private material outside the Keychain / owner-only file.
- **VM bundle data-at-rest protection**: On portable Macs (laptops), `VirtualMachineBundle.create` applies `FileProtectionType.completeUntilFirstUserAuthentication` to the bundle directory — defense-in-depth on top of FileVault for stolen-laptop-with-compromised-recovery-key scenarios. Desktops and EC2 Mac hosts stay at `.none` so pre-login LaunchDaemons can still read bundles. Operators migrate existing bundles with `spook bundle protect --all`. See [`docs/DATA_AT_REST.md`](docs/DATA_AT_REST.md) for the OWASP ASVS V6.1.1 / V6.4.1 / V14.2.6 mapping.
- **GitHub runner tokens via Keychain**: `spook create --github-token-keychain <account>` reads registration tokens from the macOS Keychain under service `com.spooktacular.github`. Tokens never reach `ps auxww`, shell history, `launchctl print`, or backup archives. Provisioning scripts that embed those tokens are written to `~/Library/Caches/com.spooktacular/provisioning/<uuid>/` with mode 0700 (owner-only) instead of the previous `/tmp` + 0755 path.
- **Distributed locking — three backends, factory-selected**: `DistributedLockFactory.makeFromEnvironment()` picks the lock implementation based on deployment context:
  - `SPOOK_DYNAMO_TABLE` set → `DynamoDBDistributedLock` — cross-region strong-consistency via DynamoDB Global Tables + conditional writes. Fortune-20 multi-region fleets where K8s Leases can't bridge regions. SigV4 signing is hand-rolled (zero AWS SDK dependency).
  - `SPOOK_K8S_API` set → `KubernetesLeaseLock` — cluster-scoped coordination via K8s Lease objects with optimistic concurrency (`resourceVersion`).
  - Default → `FileDistributedLock` — `flock(2)` over `SPOOK_LOCK_DIR` (local or NFS). Single-host and shared-filesystem deployments.
  The chosen backend is logged at startup so operators can detect unintended downgrades (a DynamoDB-expected deployment falling back to file lock would be a catastrophic multi-region coordination failure).
- **Tamper-evident audit with hardware-bound signing (RFC 6962 + S3 Object Lock + NIST SP 800-53 AU-9/AU-10; FIPS 140-3 Level 2)**: `MerkleAuditSink` uses an RFC 6962 Merkle tree. Leaf hashes use `SHA256(0x00 || data)`, interior nodes use `SHA256(0x01 || left || right)`. Signed Tree Heads sign the RFC 6962 §3.5 `TreeHeadSignature` structure (version byte 0x00 + signature_type 0x01 + milliseconds timestamp + tree_size + root) with **P-256 ECDSA, using a Secure-Enclave-bound signing key**. The private key is generated inside the SEP on first use (`SecureEnclave.P256.Signing.PrivateKey`, stored as an opaque blob in the Keychain under `SPOOK_AUDIT_SIGNING_KEY_LABEL`) and is non-exportable by hardware — a compromised controller process cannot forge tree heads even with full code-execution capability, because the SEP only signs what the daemon requests and the key material never enters the AP's address space. Inclusion proofs verify specific records in O(log n). The full sink chain composes: `OSLog` | `JSONFileAuditSink` → optional `AppendOnlyFileAuditStore` (BSD `UF_APPEND` via `chflags`, kernel-verified on init) → optional `MerkleAuditSink` → optional `S3ObjectLockAuditStore` (WORM, AWS S3 Object Lock in Compliance mode, SigV4 signing). Hosts without a Secure Enclave (bare-metal Linux controllers, unit tests) can fall back to a PEM-encoded P-256 software key at mode 0600 (`SPOOK_AUDIT_SIGNING_KEY_PATH`) — the factory refuses to build the Merkle sink without exactly one of the two key sources configured.
- **Blast radius of a compromised token**: A break-glass token grants shell execution inside the guest, but only on port 9472. Runner and read-only tokens cannot reach exec even if replayed against other ports. Child processes spawned from break-glass exec have `SPOOK_AGENT_*` and `SPOOK_AUDIT_*` stripped from their environment so a caller can't read the agent's own credentials. Use the narrowest token tier that meets your needs.
- **Server-side break-glass enforcement (four gates, all in the guest agent)**: Shell execution passes four independent server-side checks before `/bin/bash` ever runs:
  1. **Port-tier gate** — port 9472 is the only vsock port configured with `channelScope: .breakGlass`. Requests for `/api/v1/exec` on any other port are rejected at the transport layer with a 403. See `Sources/spooktacular-agent/AgentHTTPServer.swift` (`listenAll`) and `AgentRouter.endpointScope`.
  2. **Credential-path selection** — headers starting with `bgt:` go through the ticket verifier; everything else goes through the static-token path. A failed ticket verification does NOT fall through to the static-token path (would give an attacker two shots per request). See `AgentRouter.routeRequest`.
  3. **Credential check** — either (a) constant-time Bearer comparison for static tokens, or (b) full OWASP-aligned ticket verification: P-256 ECDSA signature checked against the operator-key allowlist (trust roster of per-operator Secure-Enclave-bound keys) → typed claim decode → issuer allowlist → tenant match → expiry (60s skew) → `maxUses` bound → atomic single-use consume via `UsedTicketCache`. See `Sources/spooktacular-agent/BreakGlassVerification.swift`.
  4. **Handler-tier defense-in-depth** — `handleExec(_:authTier:)` re-asserts `authTier == .breakGlass` at the handler boundary. A future routing regression, a custom vsock client, or a fallthrough in the scope table still cannot reach `/bin/bash` without a matching break-glass credential. See `AgentRouter.swift:handleExec`.
  Every `/exec` call (including denials) emits an `AuditRecord` via `SPOOK_AGENT_AUDIT_FILE` in enterprise mode. Ticket consumptions additionally log `jti`, `issuer`, `tenant`, and `reason` at `.public` so the audit trail is complete — the ticket itself stays `.private`.
- **Hardware-bound, per-operator break-glass tickets (OWASP JWT Cheat Sheet aligned; AAL3 per NIST SP 800-63B)**: Compact `bgt:<base64url-payload>.<base64url-sig>` tokens — like a JWT but **without** the algorithm header (eliminates JWT's algorithm-confusion surface rather than guarding against it). P-256 ECDSA signatures. The signing key is generated **inside the macOS Secure Enclave** on the operator's workstation and is non-exportable; every signature requires a live `.userPresence` gesture (Touch ID / Watch unlock / device passcode) at mint time. A full kernel compromise of the operator's Mac cannot exfiltrate the key — only signatures produced with live user consent. TTL capped at 1 hour by policy. Single-use by default via `UsedTicketCache`'s JTI denylist. Issuer allowlist defeats "attacker mints their own key" attacks. Tenant-scoped: a ticket for tenant A can't be replayed against tenant B. Each operator has their own SEP key; the fleet's agents trust the **union** of operator public keys, so ticket signatures cryptographically attribute a ticket to a specific operator's hardware — non-repudiation, not just self-asserted `issuer`. Operator workflow:
  ```bash
  # Per-operator setup (one-time, on each operator's own
  # workstation):
  spook break-glass keygen \
    --keychain-label alice-mbp \
    --public-key     ~/alice-break-glass.pem
  # → private key generated inside the Secure Enclave,
  #   non-exportable. Public key written as PEM SPKI.

  # Fleet trust-allowlist (each guest agent):
  SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR=/etc/spooktacular/break-glass-keys/
  SPOOK_BREAKGLASS_ISSUERS=alice@acme,bob@acme
  SPOOK_BREAKGLASS_TENANT=prod
  # Drop alice-break-glass.pem + bob-break-glass.pem into the
  # dir. Each file authorizes exactly one operator. Offboarding
  # is a single file delete — no fleet-wide key rotation.

  # During an incident (on the operator's workstation):
  spook break-glass issue --tenant prod --issuer alice@acme \
    --ttl 15m --keychain-label alice-mbp \
    --reason "runner-17 stuck in draining"
  # Touch ID prompt: "Mint a break-glass ticket for tenant prod
  #                   — runner-17 stuck in draining"
  # → bgt:eyJ...
  ```
  Software-keyed fallback (`--private-key <path>` / `--signing-key <path>`) remains for genuinely headless hosts without a Secure Enclave; the CLI wraps that path in an additional `AdminPresenceGate` check so a compromised shell still cannot read the on-disk PEM without operator consent.
- **Production preflight (fail-fast startup)**: In addition to the `HTTPAPIServer` TLS + bearer-token check, `spook serve` runs `ProductionPreflight.validate()` before binding the listener and refuses to start if a multi-tenant deployment is missing an audit sink OR an authorization service, or if `--insecure` is combined with `SPOOK_TENANCY_MODE=multi-tenant`. Every failure carries a recovery hint; there is no warn-and-continue path. See `Sources/SpookApplication/ProductionPreflight.swift`.

### Who should use Spooktacular

- DevOps teams running CI/CD on Mac hardware they own (single-tenant)
- Organizations with multiple teams sharing a Mac fleet (multi-tenant with `SPOOK_TENANCY_MODE=multi-tenant`)
- Teams that need remote desktops or code signing on dedicated Macs

### Who should NOT use Spooktacular (yet)

- Environments requiring FIPS 140-2 Level 2+ hardware-backed key custody **on virtualized deployments**. Apple Silicon hosts get Secure Enclave; CI runners inside VMs fall back to Keychain-backed software keys.
- Deployments requiring federated identity beyond OIDC/SAML — certificate-based, OIDC, and SAML 2.0 identity are supported

Signed tree heads persist across process restarts (set
`SPOOK_AUDIT_SIGNING_KEY` to a path that survives restarts; the file
is created with mode 0600 via `open(2) O_EXCL | O_NOFOLLOW` to avoid
any TOCTOU window in the default umask). Combined with
`AppendOnlyFileAuditStore` (BSD `UF_APPEND`, kernel-verified on init)
and `S3ObjectLockAuditStore` (WORM S3 Object Lock in Compliance
mode, SigV4 hand-rolled), the audit chain supports SOC 2 Type II
controls end-to-end with no external immutable-storage forwarding
required.

## Deployment Models

Spooktacular supports three deployment topologies, each with different security considerations:

- **Single-host standalone**: A single Mac runs `spook serve` (or the GUI app) and manages its own VMs. Authentication is via bearer token. This is the simplest model and suitable for small teams or individual developers. No network coordination is needed.

- **Multi-host with controller**: A Kubernetes controller (running on Linux) manages multiple Mac nodes over HTTPS with mandatory mTLS. Each Mac node runs `spook serve`. The controller presents a client certificate; nodes verify it. Bearer tokens provide secondary auth. The controller uses a dedicated ServiceAccount with least-privilege RBAC. Runner tokens are stored in Kubernetes Secrets.

- **EC2 Mac fleet**: Mac instances run on AWS EC2 dedicated hosts (e.g., `mac2-m2pro.metal`). Each host runs `spook serve` as a LaunchDaemon. In enterprise mode, hosts integrate with EC2 Host Resource Groups (HRG) for placement, implement drain procedures for 24-hour minimum allocation compliance, and can use IMDS for instance identity verification. Keychain-based secret storage is recommended over environment variables in this model.

## Deployment Classes

| Aspect | Pilot (Single-Tenant) | Enterprise Platform (Multi-Tenant) |
|--------|----------------------|-----------------------------------|
| **Status** | Supported | Supported (SPOOK_TENANCY_MODE=multi-tenant) |
| **Trust boundary** | One team per host/fleet | Multiple teams, tenant isolation |
| **Identity model** | mTLS certificates + bearer tokens | OIDC federated identity (`OIDCTokenVerifier`) + group-to-tenant mapping |
| **Authorization** | Scope-based (read/runner/break-glass) | Tenant + scope + resource policy via `MultiTenantAuthorization` on top of `RBACAuthorization` |
| **Host scheduling** | Any available node | Tenant-partitioned host pools (`TenantIsolationPolicy`) |
| **Warm-pool reuse** | Allowed with scrub validation | Same-tenant only, cross-tenant forbidden (`canReuse()`) |
| **Break-glass shell** | Available with admin controls | Disabled by default, explicit per-tenant opt-in |
| **Audit** | os.Logger + optional JSONL export + optional S3 Object Lock | Merkle-signed JSONL (`MerkleAuditSink`) + append-only file + S3 Object Lock + SIEM forwarding |
| **Locking** | `FileDistributedLock` (flock over local/NFS) | `DistributedLockFactory`: DynamoDB (cross-region, Global Tables), Kubernetes Lease, or file — selected via `SPOOK_DYNAMO_TABLE` / `SPOOK_K8S_API` / `SPOOK_LOCK_DIR` |

**Both deployment classes are supported.** Single-tenant is the recommended starting point. Multi-tenant adds OIDC identity, tenant-partitioned scheduling, hash-chained audit, and K8s distributed locking.

## Security Operations

### Severity Classification

| Severity | Response Time | Fix Target | Example |
|----------|--------------|------------|---------|
| Critical | 4 hours | 24 hours | Remote code execution, auth bypass |
| High | 24 hours | 1 week | Privilege escalation, data exposure |
| Medium | 1 week | 2 weeks | Information disclosure, DoS |
| Low | 2 weeks | Next release | Minor hardening improvements |

### Credential Rotation

- **API tokens**: Rotate via Keychain (`security delete-generic-password` + `security add-generic-password`). No restart required — server reads token on each request.
- **TLS certificates**: Replace cert/key files on disk. Server detects changes via `DispatchSource` file watcher and reloads automatically (zero-downtime rotation). The reloaded listener enforces the same TLS 1.3 floor as the initial one.
- **Guest agent tokens**: Update the token file at `/Volumes/My Shared Files/.agent-token` or the `SPOOK_AGENT_TOKEN` environment variable. Agent reads on each request.
- **Merkle audit signing key**: Rotate by replacing the file at `SPOOK_AUDIT_SIGNING_KEY` (mode 0600). The loader refuses to start if permissions are weaker than 0600, so `chmod 600` the replacement before restart. Tree heads signed with the prior key remain valid until re-signed — distribute the old public key to long-lived verifiers before rotation.

### Runtime Admin API

The HTTP API exposes runtime administration for roles, role assignments, and tenants — gated by RBAC so operators can grant, revoke, and list without editing JSON on disk and restarting:

| Endpoint | Method | Required permission | Built-in role that grants it |
|----------|--------|---------------------|------------------------------|
| `/v1/roles` | GET | `role:list` | `security-admin` |
| `/v1/roles/{actor}` | GET | `role:list` | `security-admin` |
| `/v1/roles/assign` | POST | `role:assign` | `security-admin` |
| `/v1/roles/revoke` | POST | `role:revoke` | `security-admin` |
| `/v1/tenants` | GET | `tenant:list` | `security-admin`, `platform-admin` |
| `/v1/tenants/{id}` | GET | `tenant:list` | `security-admin`, `platform-admin` |
| `/v1/tenants` | POST | `tenant:create` | `platform-admin` |
| `/v1/tenants/{id}` | PATCH / PUT | `tenant:update` | `platform-admin` |
| `/v1/tenants/{id}` | DELETE | `tenant:delete` | `platform-admin` |

Every admin call emits a structured `AuditRecord` with the authenticated caller's identity, tenant, and correlation ID — including failed authorization attempts.

### Incident Response

1. **Contain**: Stop scheduling new VMs on the affected host. In a controller deployment, cordon the node via Kubernetes.
2. **Investigate**: Query audit logs (`log show --predicate 'subsystem == "com.spooktacular.agent" AND category == "audit"' --last 1h`).
3. **Remediate**: Rotate credentials, destroy affected VMs, restore from known-good base image.
4. **Recover**: Uncordon the host, verify `spook doctor` passes, resume scheduling.

### Deployment Support Matrix

| Topology | Supported | Identity Model | Audit | Lock Backend |
|----------|-----------|---------------|-------|--------------|
| Single host, single team | Yes | Bearer token + optional TLS | OSLog / JSONL | `FileDistributedLock` (local) |
| Multi-host, single team | Yes | Mandatory mTLS + bearer token | JSONL + append-only + Merkle | `FileDistributedLock` (NFS) |
| EC2 Mac fleet | Yes | mTLS + IMDS identity | JSONL + append-only + Merkle + S3 Object Lock | `DynamoDBDistributedLock` |
| Kubernetes-managed | Yes | mTLS + ServiceAccount | Merkle + S3 Object Lock | `KubernetesLeaseLock` |
| Multi-tenant (cross-region) | Supported | OIDC/SAML + tenant isolation | Merkle + S3 Object Lock + SIEM | `DynamoDBDistributedLock` (Global Tables) |

## Reporting a Vulnerability

**Do not open a public issue for security vulnerabilities.**

Instead, please report vulnerabilities privately via one of these channels:

1. **GitHub Security Advisories** (preferred): [Report a vulnerability](https://github.com/Spooky-Labs/spooktacular/security/advisories/new)
2. **Email**: security@spooktacular.app

### What to include

- Description of the vulnerability
- Steps to reproduce
- Affected version(s)
- Potential impact

### Response timeline

- **Acknowledgment**: Within 48 hours
- **Initial assessment**: Within 1 week
- **Fix release**: Within 2 weeks for critical issues

### Scope

The following are in scope for security reports:

- The `spook` CLI tool
- The `Spooktacular` GUI app
- The `spooktacular-agent` guest agent
- The `spook-controller` Kubernetes controller
- The HTTP API server (`spook serve`)
- The website at spooktacular.app

### Out of scope

- Apple Virtualization.framework bugs (report to Apple)
- macOS kernel vulnerabilities (report to Apple)
- Denial of service via resource exhaustion (2-VM limit is kernel-enforced)

## Architectural Invariants

These rules are enforced by the compiler (separate SwiftPM targets) and runtime checks:

1. **No production control-plane call without mTLS.** Controller refuses to start without TLS certificates (`TLS_CERT_PATH`, `TLS_KEY_PATH`, `TLS_CA_PATH`). The `SPOOK_INSECURE_CONTROLLER=1` bypass exists for local development only and logs a prominent warning.
2. **No VM returned to a warm pool without positive scrub validation.** `ScrubStrategy.recycleWithValidation()` runs a verification script; failed validation triggers stop + delete via `NodeClient`.
3. **No runner considered Ready until both guest health check and GitHub registration are confirmed.** `RunnerStateMachine` transitions through `booting` (requires `.healthCheckPassed`) and `registering` (requires `.runnerRegistered`) before reaching `.ready`.
4. **No break-glass operation without separate scope and audit.** Shell execution requires `AuthScope.breakGlass` tier on vsock port 9472; every invocation produces an `AuditRecord`. Disabled by default in multi-tenant mode.
5. **No domain logic in Apple-framework adapters.** `SpookCore` and `SpookApplication` import Foundation only (compiler-enforced via separate SwiftPM targets with no framework dependencies).
6. **No Apple-framework types in domain objects.** `SpookCore` has zero framework imports beyond Foundation across all 22 source files.
7. **No tenantless request path.** `AuthorizationContext` requires `TenantID` at construction. Single-tenant deployments use `TenantID.default`.
8. **No cross-tenant warm-pool reuse.** `MultiTenantIsolation.canReuse()` returns `true` only when `fromTenant == forTenant`. Enforced in `RunnerPoolReconciler` before every recycle operation.
