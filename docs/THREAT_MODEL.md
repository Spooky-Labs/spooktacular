# Spooktacular Threat Model

**Status:** Living document — updated per release.
**Owner:** security@spooktacular.app
**Scope:** `spook` CLI, `Spooktacular` GUI, `spooktacular-agent`, `spook-controller`, the HTTP API (`spook serve`).
**Method:** STRIDE per asset, with explicit assumptions, attacker capabilities, and references to the code that mitigates each risk. Re-reviewed on every release-note cycle.

## 1. Assets

| Asset | Why it matters | Custodian |
|-------|----------------|-----------|
| Guest macOS VM | Holds CI secrets, source code, signing material | Host (`VZVirtualMachine`) |
| Host Mac | Unit of compute; compromise = fleet compromise | Operator |
| mTLS client certs | Identify Mac nodes to the controller | Keychain |
| Guest agent tokens | Scope-tiered API auth (read / runner / break-glass) | Keychain + shared-folder file |
| Merkle signing key | Non-repudiation of audit log | `open(2) O_EXCL, 0600` file |
| AWS credentials | DynamoDB lock, S3 Object Lock writes | Environment / IAM role |
| OIDC / SAML IdP trust | Federated identity for humans | JWKS + X.509 cert pinning |

## 2. Actors

- **Legitimate operator** — manages the fleet, holds `platform-admin` or `security-admin` role.
- **CI user** — triggers builds, has `ci-operator` role. Does not hold break-glass.
- **Auditor** — `security-admin` read-only; reviews Merkle log + tenants.
- **Adversary-tenant** — a neighboring tenant in a multi-tenant deployment, attempting cross-tenant access.
- **Network attacker** — on-path for control-plane and guest-agent traffic.
- **Supply-chain attacker** — targets the build pipeline or dependencies.
- **Malicious guest process** — compromised CI workload attempting VM escape.

## 3. Trust boundaries

```
┌─────────────────┐   mTLS TLS 1.3    ┌───────────────────┐
│  CI / Operator  │ ─────────────────▶│  spook-controller │
└─────────────────┘                    └────────┬──────────┘
                                                │ mTLS TLS 1.3
                                                ▼
                                       ┌───────────────────┐
                                       │  Mac host (spook  │
                                       │  serve, HTTP API) │
                                       └────────┬──────────┘
                                                │ vsock (host-CID pinned)
                                                ▼
                                       ┌───────────────────┐
                                       │  Guest macOS VM   │
                                       │  (spooktacular-   │
                                       │  agent, 3 tiers)  │
                                       └───────────────────┘
```

Every arrow is a trust boundary with explicit authentication, encryption, and audit.

## 4. STRIDE per asset

### 4.1 HTTP control plane (`spook serve`)

| Threat | Vector | Mitigation | Code reference |
|--------|--------|------------|----------------|
| **Spoofing** | Unauthenticated caller reaches API | mTLS + bearer token required in production; init throws without both | `HTTPAPIServer.init` |
| **Spoofing** | JWT from wrong IdP | Issuer + audience + JWKS signature verification, 60s skew window | `OIDCTokenVerifier.verify` |
| **Tampering** | TLS downgrade to 1.2 | `sec_protocol_options_set_min_tls_protocol_version(.TLSv13)` on init and on hot reload | `HTTPAPIServer.init`, `reloadTLS` |
| **Repudiation** | Operator denies making a change | Every API call emits an `AuditRecord` with the verified caller identity; Merkle tree + S3 Object Lock | `emitAPIAudit`, `MerkleAuditSink`, `S3ObjectLockAuditStore` |
| **Information disclosure** | Timing oracle on bearer comparison | Constant-time compare | `constantTimeEqual` |
| **DoS** | Flooded connections | Per-IP rate limit (`SPOOK_RATE_LIMIT`), max-connections gate, request-size + timeout limits | `HTTPAPIServer.handleNewConnection` |
| **Elevation of privilege** | Missing RBAC on an endpoint | Every dispatcher path runs `authService.authorize` before handler; deny-by-default | `routeRequest` |

### 4.2 Guest agent (`spooktacular-agent`)

| Threat | Vector | Mitigation | Code reference |
|--------|--------|------------|----------------|
| **Spoofing** | Host impersonation over vsock | Host CID pinning rejects peer-to-peer attempts | `SpookAgent.acceptLoop` |
| **Spoofing** | Network-routed connection | vsock only — no TCP socket exposed in guest | `SpookAgent.bindVsock` |
| **Tampering** | Replay of captured exec command | Break-glass on port 9472 only; runner/read-only tokens 403 on exec | `AgentRouter.handleExec`, port binding tier |
| **Repudiation** | Shell exec without audit | Each exec writes an `AuditRecord` via `SPOOK_AGENT_AUDIT_FILE`; append-only in enterprise mode | `AgentRouter.emitAgentAudit` |
| **Information disclosure** | Child shell inherits auth tokens | `SPOOK_AGENT_*` and `SPOOK_AUDIT_*` scrubbed from `process.environment` before exec | `AgentRouter.handleExec` |
| **Information disclosure** | Path traversal via `/fs/list` | `fsAllowedRoots` check + `standardizedFileURL.resolvingSymlinksInPath()` | `AgentRouter.handleListFS` |
| **DoS** | Child hangs on SIGTERM to hold exec slot | SIGKILL escalation 5s after SIGTERM, `os_unfair_lock`-protected slot counter | `AgentRouter.handleExec` |
| **Elevation of privilege** | Command injection via command string | Command passed as array to `/bin/bash -c`; SSH path POSIX-escapes each token | `AgentRouter.handleExec`, `Exec.posixShellEscape` |

### 4.3 Audit subsystem

| Threat | Vector | Mitigation | Code reference |
|--------|--------|------------|----------------|
| **Tampering** | In-place edit of JSONL file | `AppendOnlyFileAuditStore` sets `UF_APPEND` via `chflags`, kernel-verified on init | `AppendOnlyFileAuditStore.init` |
| **Tampering** | Local file exfiltration + replacement | S3 Object Lock (Compliance mode) is WORM at the storage layer | `S3ObjectLockAuditStore` |
| **Tampering** | Forged STH | Ed25519 signature over RFC 6962 §3.5 TBS bytes (version + sig_type + ms timestamp + size + root) | `MerkleAuditSink.signedTreeHead` |
| **Repudiation** | Call-chain minting new record id | Merkle sink preserves caller's `AuditRecord.id` and `timestamp` via explicit-id init | `MerkleAuditSink.record`, `AuditRecord.init(id:…)` |
| **Information disclosure** | Guest stdout/stderr in host logs | `OSLog` privacy `.private(mask: .hash)` on all guest output | `VsockProvisioner.provision` |
| **Information disclosure** | Signing key exfiltration | `open(2) O_CREAT | O_EXCL | O_NOFOLLOW, 0600` — no umask-default TOCTOU window | `AuditSinkFactory.loadOrCreateSigningKey` |
| **DoS** | Signing failure crashing audit pipeline | `signedTreeHeadOrUnsigned()` returns an unsigned fallback and logs the error; STH throwing variant is reserved for interactive callers | `MerkleAuditSink.signedTreeHeadOrUnsigned` |

### 4.4 Multi-tenant boundary

| Threat | Vector | Mitigation | Code reference |
|--------|--------|------------|----------------|
| **Elevation of privilege** | Tenant A calls tenant B's VMs | `TenantIsolationPolicy` filters pools and runner groups by tenant on every dispatch | `MultiTenantIsolation` |
| **Elevation of privilege** | Warm-pool VM reused cross-tenant | `canReuse()` returns `true` only when `fromTenant == forTenant`; reconciler enforces before recycle | `RunnerPoolReconciler.recycle` |
| **Elevation of privilege** | Resource exhaustion by noisy tenant | Per-tenant `TenantQuota` evaluated before admission | `TenantQuota.evaluate` |
| **Tampering** | Rogue admin edits role file on disk | Admin REST endpoints (`/v1/roles*`, `/v1/tenants*`) require `role:*` / `tenant:*` permissions, every mutation audited | `HTTPAPIServer.handleRoleAPI`, `handleTenantAPI` |

### 4.5 Distributed coordination

| Threat | Vector | Mitigation | Code reference |
|--------|--------|------------|----------------|
| **Tampering** | Split-brain across regions | DynamoDB Global Tables + `ConditionExpression` compare-and-swap on `version` + `holder` | `DynamoDBDistributedLock.renew` |
| **Tampering** | Silent lock-backend downgrade | Factory logs chosen backend at startup; `SPOOK_DYNAMO_TABLE` without AWS creds throws (no fallback) | `DistributedLockFactory.makeFromEnvironment` |
| **Repudiation** | Lock release by a different holder | DeleteItem conditional on `version` and `holder` — mismatch logs + skips | `DynamoDBDistributedLock.release` |

### 4.6 Guest-to-host escape

VM escape is the highest-severity attack; mitigation relies on **Apple's Virtualization.framework** + hardened runtime + no helper-daemon privilege escalation. Spooktacular does **not** harden against a kernel-level VM escape — that is Apple's responsibility. Controls we apply:

- Guest agent runs as a regular user (not `root`). Shared-folder LaunchDaemon is the only privileged surface — verified by code review to only handle file-mount mediation with no `exec`.
- Break-glass token file lives on a read-only shared folder in production (operator-controlled mount).
- Guest-to-host data channel is vsock with host-CID check; guests cannot reach the host's network namespace.

A kernel-level escape CVE in `Virtualization.framework` is **out of scope** — report to Apple, rotate credentials per § Credential Rotation.

### 4.7 Insider threats

Insider risk is where most mature programs actually get hurt, and it is worth its own STRIDE row set. The threats below assume the actor has **legitimate initial access** to something — that is what makes them "insider" rather than "external attacker." Mitigations here pair technical controls with non-repudiation (Merkle audit + per-operator SEP keys) so post-incident attribution is cryptographic, not testimonial.

| Threat | Vector | Mitigation | Code / tests reference |
|--------|--------|------------|------------------------|
| **Repudiation / EoP** — disgruntled security-admin holding a break-glass key misuses it | Legitimate SEP-bound break-glass key + `security-admin` role; issues a ticket for an unrelated tenant during an unsanctioned window | Tenant scoping on ticket mint (`bgt:` payload carries `tenant`); per-operator key makes the signature cryptographically attributable; every mint + consume emits an `AuditRecord` with `jti`, `issuer`, `tenant`, `reason`; monitoring alerts on break-glass use outside change-management windows; offboarding is a single-file delete of the operator's public-key PEM | `Sources/SpookCore/BreakGlassTicket.swift`, `Sources/spooktacular-agent/BreakGlassVerification.swift`, `Sources/SpookApplication/UsedTicketCache.swift`, [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md) Runbook 1 |
| **EoP** — compromised ServiceAccount (controller pod) | Attacker lands shell in controller pod, holds its K8s ServiceAccount token | Least-privilege RBAC on the ServiceAccount; mTLS client cert is **separately** required to reach `spook serve` (token alone is insufficient); SPOOK_INSECURE_CONTROLLER refuses to set itself in production; break-glass is disabled by default in multi-tenant mode; audit records every admission with the verified mTLS identity, not the token | `HTTPAPIServer.init` (TLS required), `ProductionPreflight.validate()`, `Sources/spook-controller/` |
| **EoP** — CI user escalates to platform-admin | CI user abuses `/v1/roles/assign` to grant themselves `platform-admin` | `/v1/roles/assign` requires `role:assign` permission, which only `security-admin` holds; separation of duties enforced by the RBAC model (platform-admin can admin platform, security-admin admins identity — neither can self-promote); every mutation emits `AuditRecord` including failed attempts | `Sources/SpookInfrastructureApple/HTTPAPIServer.swift` (`handleRoleAPI`), `Sources/SpookCore/RBACModel.swift` |
| **Repudiation** — audit-key operator forges or back-dates records | Operator with access to the Merkle signing key emits STHs that rewrite history | Key is generated **inside the Secure Enclave** and non-exportable — the operator has signing capability but cannot copy the key material elsewhere; `AppendOnlyFileAuditStore` sets `UF_APPEND` (kernel-enforced); S3 Object Lock in Compliance mode is WORM at AWS; any attempt to back-date appears as divergence between local tree, append-only file, and S3 copy — verifiable by anyone holding the current public key; rotation runbook (Runbook 3) cryptographically chain-links old and new keys | `Sources/SpookInfrastructureApple/AuditSinkFactory.swift` (SEP path), `Sources/SpookInfrastructureApple/MerkleAuditSink.swift`, [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md) Runbook 3 |
| **Information disclosure** — operator with Keychain access exfiltrates mTLS certs | Logged-in operator on an EC2 Mac reads the Keychain-stored client cert and uses it from outside the fleet | mTLS private keys are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — they do not sync via iCloud Keychain; on SEP-capable hosts the key can be bound with `kSecAttrTokenIDSecureEnclave` (non-exportable); cert rotation is zero-downtime via `DispatchSource` hot-reload, so suspected exfiltration triggers a same-hour rotation without an outage; audit shows every API request the cert authenticated, so post-rotation traffic coming from the exfiltrated cert produces an alert-able delta | `Sources/SpookInfrastructureApple/KeychainTLSProvider.swift`, `Sources/SpookInfrastructureApple/HTTPAPIServer.swift` (`reloadTLS`), [`INCIDENT_RESPONSE.md`](INCIDENT_RESPONSE.md) Runbook 2 |

Insider threats are **never fully eliminated by code** — the defense depth is (a) minimize blast radius per action via scope tiers, (b) make every action cryptographically attributable via SEP-bound per-operator keys + Merkle-signed audit, and (c) provide a runbook to rotate the compromised identity in minutes, not weeks.

## 5. Supply-chain threats

| Threat | Mitigation |
|--------|------------|
| Tampered build output | Hardened Runtime + notarization via `codesign --timestamp` + `--options runtime`; ad-hoc builds skip the TSA |
| Tampered entitlements | Entitlements pinned in-tree (`Spooktacular.entitlements`, `SpookCLI.entitlements`); `com.apple.security.app-sandbox` is explicit (`true` for GUI, `false` for CLI) so reviewers see intent |
| Dependency substitution | **Zero third-party dependencies.** Only Apple SDKs: Foundation, CryptoKit, Security, Network, Virtualization, os |
| Source repo compromise | All releases signed + notarized; PRs require review; GitHub branch protection on `main` |

## 6. Side-channel risks

| Threat | Mitigation |
|--------|------------|
| Timing oracle on bearer token | Constant-time compare in `AgentRouter.constantTimeEqual` and `HTTPAPIServer.constantTimeEqual` |
| Timing oracle on JWT signature | CryptoKit's `SecKeyVerifySignature` — constant-time implementation |
| Cache side-channel across tenants | `canReuse()` enforces same-tenant; scrub validation runs between jobs when reuse is allowed |
| Rowhammer / Spectre | Accept inherent: requires kernel-level Apple Silicon mitigations we do not re-implement |

## 7. Residual risks and explicit non-goals

- **Pre-auth DoS via network flooding**: rate-limited per IP, not per ASN — a botnet can still exhaust bandwidth. Defense-in-depth requires an upstream WAF.
- **Compromised build machine**: this threat model assumes a trustworthy build host. CI attests via reproducible build, but a malicious `build-app.sh` signer with a valid identity could ship signed malware.
- **Physical access to the Mac**: full-disk encryption + Secure Enclave + firmware password is the operator's responsibility.
- **Voice-activated / Siri-trigger misuse**: App Intents do not grant anything the caller wouldn't have via the CLI; intents go through the same RBAC gate.

## 8. Review cadence

- **Every release**: walk the "What this security model covers" section of `SECURITY.md` against this doc. Open a tracking issue for each divergence.
- **Quarterly**: third-party penetration test (see § 9).
- **Annually**: end-to-end threat-model refresh — new actors, new assets, new dependencies.

## 9. External validation

The following are open tracking items; the threat model is **not** a substitute for them:

- [ ] Third-party penetration test (scope: HTTP API, guest agent, controller). Target: 2026 Q2.
- [ ] SOC 2 Type II attestation including the audit chain (append-only + Merkle + S3 Object Lock).
- [ ] CIS Benchmark conformance scan for the .app bundle.
- [ ] Red-team exercise simulating a CI-user break-glass escalation attempt.

Each item's close-out will link back to this doc with the report identifier and remediation notes.
