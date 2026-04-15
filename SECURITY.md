# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| N (current) | Yes   |
| N-1         | Yes   |
| < N-1       | No    |

We support the current release and the immediately prior release (N and N-1). Older versions do not receive security patches. Please update to a supported version before reporting a vulnerability.

## Security Model

Spooktacular currently supports **Pilot (Single-Tenant)** deployments — one team per trust domain, on Mac hardware that team controls. See [Deployment Classes](#deployment-classes) for the full comparison between Pilot and the planned Enterprise Platform mode.

In Pilot mode, the security model assumes the operator controls both the host and all guests. Production deployments require mandatory mTLS for controller-to-node traffic, Keychain-backed secret storage, and three-tier guest agent authorization.

### What this security model covers

- **Host ↔ Guest isolation**: VMs run in Apple's Virtualization.framework sandbox. The guest agent communicates over vsock (not the network), with host CID verification rejecting peer-to-peer connections.
- **Separate vsock channels per capability tier**: The guest agent binds three vsock ports, each enforcing a maximum scope at the transport layer before token authentication:
  - Port 9470: read-only (health, inspection, diagnostics)
  - Port 9471: runner control (mutation except exec)
  - Port 9472: break-glass (exec — disabled by default, requires explicit token)
  Requests exceeding the channel's scope are rejected with 403 at the socket accept layer.
- **HTTP API authentication**: The HTTP API requires TLS in production (`--tls-cert`/`--tls-key`) and a bearer token (`SPOOK_API_TOKEN`). Only `/health` is unauthenticated (liveness probe). Production startup fails without TLS unless `--insecure` is explicitly set (development only).
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

- **No federated identity**: mTLS is mandatory in production, but identity is certificate-based, not federated. There is no integration with OIDC, SAML, or cloud IAM providers.
- **No per-user identity**: Authentication is token-based, not user-based. A single shared token authenticates all requests. There is no RBAC beyond the three-tier agent scope system.
- **No distributed locking**: Capacity enforcement uses `flock(2)`, which is per-host only. In a multi-controller deployment, each controller must target distinct hosts.
- **No tamper-resistant audit**: Audit records are structured (JSONL with actor, tenant, scope, resource, outcome) and can be forwarded to a SIEM via `JSONFileAuditSink`. However, logs are not cryptographically signed or append-only. Operators should forward to their own tamper-resistant storage.
- **Blast radius of a compromised token**: A break-glass token grants shell execution inside the guest, but only on port 9472. Runner and read-only tokens cannot reach exec even if replayed against other ports. Use the narrowest token tier that meets your needs.

### Who should use Spooktacular

- DevOps teams running CI/CD on Mac hardware they own
- Teams that need remote desktops or code signing on dedicated Macs
- Operators comfortable with single-tenant security (one team per host)

### Who should NOT use Spooktacular (yet)

- Multi-tenant environments where untrusted users share the same host
- Environments requiring SOC 2 Type II compliance for the VM management layer
- Deployments requiring per-user RBAC or federated identity (OIDC/SAML)

## Deployment Models

Spooktacular supports three deployment topologies, each with different security considerations:

- **Single-host standalone**: A single Mac runs `spook serve` (or the GUI app) and manages its own VMs. Authentication is via bearer token. This is the simplest model and suitable for small teams or individual developers. No network coordination is needed.

- **Multi-host with controller**: A Kubernetes controller (running on Linux) manages multiple Mac nodes over HTTPS with mandatory mTLS. Each Mac node runs `spook serve`. The controller presents a client certificate; nodes verify it. Bearer tokens provide secondary auth. The controller uses a dedicated ServiceAccount with least-privilege RBAC. Runner tokens are stored in Kubernetes Secrets.

- **EC2 Mac fleet**: Mac instances run on AWS EC2 dedicated hosts (e.g., `mac2-m2pro.metal`). Each host runs `spook serve` as a LaunchDaemon. In enterprise mode, hosts integrate with EC2 Host Resource Groups (HRG) for placement, implement drain procedures for 24-hour minimum allocation compliance, and can use IMDS for instance identity verification. Keychain-based secret storage is recommended over environment variables in this model.

## Deployment Classes

| Aspect | Pilot (Single-Tenant) | Enterprise Platform (Multi-Tenant) |
|--------|----------------------|-----------------------------------|
| **Status** | Supported | Planned |
| **Trust boundary** | One team per host/fleet | Multiple teams, tenant isolation |
| **Identity model** | mTLS certificates + bearer tokens | Federated identity (OIDC/SAML) + per-user RBAC |
| **Authorization** | Scope-based (read/runner/break-glass) | Tenant + scope + resource policy |
| **Host scheduling** | Any available node | Tenant-partitioned host pools |
| **Warm-pool reuse** | Allowed with scrub validation | Same-tenant only, cross-tenant forbidden |
| **Break-glass shell** | Available with admin controls | Disabled by default, explicit per-tenant opt-in |
| **Audit** | os.Logger (Console.app, `log show`) | External SIEM forwarding required |
| **Locking** | Per-host flock(2) | Distributed coordination (planned) |

**Current recommendation:** Deploy as Pilot (Single-Tenant) on isolated EC2 Mac hosts owned by one team. Enterprise Platform mode requires federated identity, tenant isolation, and externalized audit — tracked in the [roadmap](docs/superpowers/specs/2026-04-14-fortune20-build-plan.md).

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
- **TLS certificates**: Replace cert/key files on disk. Server detects changes via `DispatchSource` file watcher and reloads automatically (zero-downtime rotation).
- **Guest agent tokens**: Update the token file at `/Volumes/My Shared Files/.agent-token` or the `SPOOK_AGENT_TOKEN` environment variable. Agent reads on each request.

### Incident Response

1. **Contain**: Stop scheduling new VMs on the affected host. In a controller deployment, cordon the node via Kubernetes.
2. **Investigate**: Query audit logs (`log show --predicate 'subsystem == "com.spooktacular.agent" AND category == "audit"' --last 1h`).
3. **Remediate**: Rotate credentials, destroy affected VMs, restore from known-good base image.
4. **Recover**: Uncordon the host, verify `spook doctor` passes, resume scheduling.

### Deployment Support Matrix

| Topology | Supported | Identity Model | Audit |
|----------|-----------|---------------|-------|
| Single host, single team | Yes | Bearer token + optional TLS | os.Logger |
| Multi-host, single team | Yes | Mandatory mTLS + bearer token | os.Logger |
| EC2 Mac fleet | Yes | mTLS + IMDS identity | os.Logger + CloudWatch forwarding |
| Multi-tenant | Planned | Federated identity + tenant isolation | External SIEM required |

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
4. **No break-glass operation without separate scope and audit.** Shell execution requires `AuthScope.breakGlass` tier; every invocation is audit-logged at `.notice` level. Disabled by default in multi-tenant mode (planned).
5. **No domain logic in Apple-framework adapters.** `SpookCore` and `SpookApplication` import Foundation only (compiler-enforced via separate SwiftPM targets with no framework dependencies).
6. **No Apple-framework types in domain objects.** `SpookCore` has zero framework imports beyond Foundation across all 22 source files.
7. **No tenantless request path.** `AuthorizationContext` requires `TenantID` at construction. Single-tenant deployments use `TenantID.default`.
8. **No cross-tenant warm-pool reuse.** `MultiTenantIsolation.canReuse()` returns `true` only when `fromTenant == forTenant`. (Multi-tenant mode is planned.)
