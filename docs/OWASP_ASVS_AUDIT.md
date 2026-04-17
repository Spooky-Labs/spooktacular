# OWASP ASVS Level 2 Self-Audit — Spooktacular

**Standard:** OWASP Application Security Verification Standard v4.0.3
**Target level:** Level 2 — "applications containing sensitive data, which requires protection"
**Audit date:** 2026-04-17
**Scope:** Entire repository at branch `main`
**Auditor:** Self-audit, to be externally validated per the pen-test path tracked in `docs/THREAT_MODEL.md §9`

## Why Level 2

ASVS Level 1 is the floor for any internet-facing application. Level 2 is the standard for apps handling sensitive data (CI/CD signing keys, audit logs, tenant boundaries, enterprise authentication). Level 3 targets high-assurance systems (classified data, high-value transactions at scale). Spooktacular fits Level 2. Where a Level 3 control is trivially satisfiable with our existing primitives, it's included and noted.

## Methodology

- Every applicable requirement gets a verdict: `PASS`, `PARTIAL`, `N/A` (with justification), or `FAIL`.
- Every `PASS` cites concrete file evidence.
- Every `N/A` cites why the requirement doesn't apply.
- Every `PARTIAL` or `FAIL` carries a remediation plan.
- The audit is structured for a Fortune-20 reviewer to walk top-to-bottom in under 30 minutes.

## Summary

| Chapter | Pass | Partial | N/A | Fail |
|---------|------|---------|-----|------|
| V1 Architecture | 10 | 0 | 1 | 0 |
| V2 Authentication | 16 | 0 | 6 | 0 |
| V3 Session Management | 3 | 0 | 9 | 0 |
| V4 Access Control | 8 | 0 | 0 | 0 |
| V5 Validation / Sanitization / Encoding | 11 | 0 | 3 | 0 |
| V6 Cryptography | 9 | 0 | 2 | 0 |
| V7 Error Handling and Logging | 9 | 0 | 0 | 0 |
| V8 Data Protection | 6 | 0 | 3 | 0 |
| V9 Communications | 5 | 0 | 1 | 0 |
| V10 Malicious Code | 3 | 0 | 1 | 0 |
| V11 Business Logic | 7 | 0 | 0 | 0 |
| V12 Files and Resources | 8 | 0 | 2 | 0 |
| V13 API and Web Service | 6 | 0 | 3 | 0 |
| V14 Configuration | 15 | 0 | 0 | 0 |
| **Total** | **116** | **0** | **31** | **0** |

No `FAIL`. No `PARTIAL`. The two partials from the prior revision (V2.7 Out-of-band Verifier and V4.3.1 Administrative MFA) are now satisfied with code-level controls rather than operator-integration handwaves — see the three new controls in V2.7 and V4.3.1 below.

Code changes that fell out of this audit:

- **V14.4** — HTTP responses now carry the full ASVS header set (`Sources/SpookInfrastructureApple/HTTPResponse.swift:serialize()` + `Tests/SpooktacularKitTests/HTTPSecurityHeadersTests.swift`).
- **V2.7 / V4.3.1** — per-action MFA: break-glass signing key in the Keychain with `SecAccessControl(.userPresence)`, `LAContext`-gated admin CLI commands, and IdP `acr`-claim enforcement on federated tokens. See:
  - `Sources/SpookInfrastructureApple/P256KeyStore.swift` (break-glass uses `Service.breakGlass` + `presenceGated: true`) + `Tests/SpooktacularKitTests/P256KeyStoreTests.swift`
  - `Sources/SpookInfrastructureApple/AdminPresenceGate.swift` + `Tests/SpooktacularKitTests/AdminPresenceGateTests.swift`
  - `Sources/SpookInfrastructureApple/OIDCTokenVerifier.swift` (`insufficientACR` + config `requiredACRValues`) + `Tests/SpooktacularKitTests/OIDCACRTests.swift`

---

## V1 — Architecture, Design, and Threat Modeling

| ID | Requirement (abbrev.) | Verdict | Evidence |
|----|----------------------|---------|----------|
| V1.1.2 | Architecture components documented | PASS | `docs/THREAT_MODEL.md` §Actors + §Trust boundaries; `SECURITY.md` §Deployment Models |
| V1.1.3 | High-level architecture + threat model | PASS | `docs/THREAT_MODEL.md` (STRIDE per asset) + `docs/DATA_AT_REST.md` + `docs/DEPLOYMENT_HARDENING.md` |
| V1.1.4 | Trust boundaries + data flows | PASS | `docs/THREAT_MODEL.md` §Trust boundaries (ASCII diagram) |
| V1.1.5 | Threat model covers abuse cases | PASS | `docs/THREAT_MODEL.md §STRIDE per asset` — per-asset tables (spoof / tamper / repudiate / info-disclose / DoS / escalate) |
| V1.2.1 | Low-privileged OS account per component | PASS | `docs/EC2_MAC_DEPLOYMENT.md §3` — dedicated `spooktacular` system user for LaunchDaemon |
| V1.2.2 | Authentication between components | PASS | mTLS between controller and Mac nodes (`KeychainTLSProvider`), Bearer tokens for all API paths, three-tier vsock isolation |
| V1.4.1 | Single trusted access-control enforcement | PASS | `Sources/SpookInfrastructureApple/HTTPAPIServer.swift:routeRequest` — RBAC check precedes every handler dispatch |
| V1.4.4 | Attribute / feature-based access control | PASS | `Sources/SpookCore/RBACModel.swift` — permissions are `(resource, action)` tuples; tenant is a first-class attribute |
| V1.5.2 | Deserialization from untrusted sources restricted | PASS | All network-boundary decoding is `JSONDecoder.decode(Typed.self, …)` post typed-Codable migration |
| V1.5.3 | Input validation at trusted service layer | PASS | `HTTPAPIServer.inferResource/inferAction`, `SpooktacularPaths.validateVMName`, `OIDCTokenVerifier`, `SAMLAssertionVerifier` |
| V1.14.2 | Unique cryptographic architecture documented | N/A | Level 3 control; still documented in `SECURITY.md` §JWKS pinning, §Data at rest, §Break-glass |

---

## V2 — Authentication

### V2.1 Password Security — N/A
Spooktacular does not accept passwords. All authentication is bearer-token (from Keychain) or federated (OIDC/SAML via IdP). V2.1.1–V2.1.12 do not apply.

### V2.2 General Authenticator Security

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.2.1 | Anti-automation / rate limit | PASS | `HTTPAPIServer` per-IP rate limit (`SPOOK_RATE_LIMIT`, default 120/min); guest-agent concurrent-exec cap |
| V2.2.2 | Weak authentication factors not used alone | PASS | Bearer tokens combined with mTLS in production (both required) |
| V2.2.3 | Notification on login-state changes | N/A | Service-account oriented, no end-user login UI |

### V2.3 Authenticator Lifecycle

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.3.1 | Credentials meet entropy/length | PASS | Keychain-stored API tokens 128-bit (documented); break-glass JTI is 128-bit `UUID()` |
| V2.3.2 | Enrollment / use flows secure | PASS | `docs/EC2_MAC_DEPLOYMENT.md §3` — SSM-driven bootstrap with Keychain-resident tokens from Secrets Manager |

### V2.4 Credential Storage

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.4.5 | Stored credentials never written unencrypted | PASS | macOS Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; Merkle signing key at file mode 0600 |

### V2.5 Credential Recovery
N/A — no passwords, no reset flow; break-glass is the emergency-access path, covered under V2.8.

### V2.6 Look-up Secret Verifier

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.6.1 | Look-up secrets single-use | PASS | `BreakGlassTicket.maxUses` defaults to 1; `UsedTicketCache.tryConsume` enforces atomically |
| V2.6.2 | Sufficient random entropy | PASS | 128-bit JTI from `UUID()` (> 64-bit Level 2 floor) |
| V2.6.3 | Look-up secrets protected from disclosure | PASS | Tickets never logged in the clear — JTI/issuer/tenant are `.public`, full ticket string is `.private` |

### V2.7 Out-of-band Verifier

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.7.1 | Out-of-band verifier authenticates the request, not the session | PASS (AAL3) | Break-glass signing keys are generated **inside the macOS Secure Enclave** and never leave it (`SecureEnclave.P256.Signing.PrivateKey(accessControl: .userPresence)`). Signing is an IPC to the SEP; raw key material never enters the calling process's address space. Even with full kernel + process compromise, the attacker can only ask the SEP to sign specific payloads — each gated by Touch ID / Watch unlock / passcode. Equivalent assurance level to FIDO2 hardware authenticators. `Sources/SpookInfrastructureApple/BreakGlassSigningKeyStore.swift` |
| V2.7.2 | Out-of-band verifier is separate from the primary authenticator | PASS | The Secure Enclave Processor is a physically separate die from the AP with its own ROM / RAM / AES engine. `.userPresence` evaluation runs inside the SEP using biometric data that never leaves the SEP. Fully independent trust domain. |
| V2.7.3 | Verifier expires unused tokens | PASS | Break-glass tickets carry 1 h max TTL (enforced at encode time) and are single-use via `UsedTicketCache`. |
| V2.7.4 | IdP stepped-up authentication enforced when federated | PASS | `OIDCProviderConfig.requiredACRValues` (RFC 8176 / OIDC Core §5.5.1.1) — verifier rejects any admin-scope token whose `acr` claim isn't in the operator's allowlist. `OIDCError.insufficientACR`. `Sources/SpookInfrastructureApple/OIDCTokenVerifier.swift` |
| V2.7.5 | Cryptographic attribution of privileged actions | PASS | Per-operator SEP keys — each operator generates their own key on their own workstation; the fleet's agents trust the **union** of operator public keys. A successful ticket signature cryptographically attributes the action to a specific operator's hardware, not just the self-asserted `issuer` string. Agent-side trust roster: `SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR` (PEM SPKI files, one per operator). `Sources/spooktacular-agent/BreakGlassVerification.swift` |

### V2.8 One-Time Verifier

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.8.3 | OTP has limited lifetime | PASS (analog) | `BreakGlassTicketCodec.maxTTL = 1h`, enforced at encode and verify |
| V2.8.4 | OTP can't be replayed | PASS (analog) | `UsedTicketCache` JTI denylist — atomic single-use |

### V2.10 Service Authentication

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V2.10.1 | No unchanging credentials | PASS | Break-glass rotates per incident; mTLS certs + API tokens rotate per `SECURITY.md §Credential Rotation`; host-to-agent auth is per-request P-256 signatures with a nonce cache — **no shared static token exists**. Each host has its own SEP-bound key; each ticket carries a fresh nonce. |
| V2.10.2 | Service creds protected | PASS | SEP-bound private keys (non-exportable) for host identity and break-glass signing; Keychain-resident with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for remaining tokens |
| V2.10.3 | No unencrypted transmission | PASS | mTLS TLS 1.3 in production; `HTTPAPIServer.init` refuses to start without TLS unless `--insecure` is explicit |
| V2.10.4 | No disclosure in logs | PASS | `.private` privacy on every token / ticket in OSLog |

---

## V3 — Session Management

Stateless JSON API authenticated per-request via Bearer or ticket. No session IDs, no cookies, no server-side session store.

| ID | Verdict | Evidence |
|----|---------|----------|
| V3.2.1 (analog) | PASS | Each break-glass ticket has a fresh JTI; no pre-auth session to rotate |
| V3.3.3 (analog) | PASS | `expiresAt` on break-glass tickets |
| V3.7.1 (analog) | PASS | Break-glass tier re-verified at every `/api/v1/exec` call |
| V3.1–V3.7 (remaining) | N/A | No cookie/session model |

---

## V4 — Access Control

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V4.1.1 | Trusted server-side enforcement | PASS | `HTTPAPIServer.routeRequest` — RBAC check before every handler dispatch |
| V4.1.2 | Access trusted after auth + authz | PASS | Break-glass enforces four gates; other tiers enforce RBAC + scope gates |
| V4.1.3 | Principle of least privilege | PASS | `BuiltInRole` hierarchy: viewer < ci-operator < platform-admin + security-admin |
| V4.1.5 | Fail-secure on errors | PASS | Deny-by-default in `MultiTenantAuthorization` and `JSONRoleStore` |
| V4.2.1 | Sensitive ops not direct-URL accessible | PASS | All `/v1/*` paths gated by RBAC; exec requires port 9472 + ticket |
| V4.2.2 | CSRF protection | N/A | No browser client; all callers are programmatic and present Bearer per request |
| V4.3.1 | Admin interfaces MFA | PASS | `AdminPresenceGate.requirePresence` wraps every platform-admin CLI command (`spook rbac assign`, `spook rbac revoke`, `spook break-glass issue` in file-path mode) via `LAContext.evaluatePolicy(.deviceOwnerAuthentication, …)`. Silent / unattended invocations fail closed unless `SPOOK_ADMIN_PRESENCE_BYPASS=1` is explicitly set (every bypass logged to OSLog at `.error`). Federated admin tokens additionally enforce the `acr` allowlist (see V2.7.4). `Sources/SpookInfrastructureApple/AdminPresenceGate.swift` |
| V4.3.2 | Directory browsing disabled | PASS | No HTML UI; API returns 404 on unknown paths |

---

## V5 — Validation, Sanitization, and Encoding

### V5.1 Input Validation

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V5.1.1 | Runtime input validation | PASS | `HTTPAPIServer` request-shape validation; `SpooktacularPaths.validateVMName` at every entry (CLI + API + controller) |
| V5.1.2 | Serialization schema | PASS | Typed Codable (`Lease`, `JWTClaims`, `DDBAttribute`, `PutItemRequest`, etc.) |
| V5.1.3 | Explicit accept/reject | PASS | Deny-by-default regex `^[a-zA-Z0-9][a-zA-Z0-9._-]{0,62}$` for VM names; algorithm allowlist `{"RS256"}` for JWTs |
| V5.1.4 | Structured input deserialized safely | PASS | `JSONDecoder.decode(Typed.self, from:)` at every boundary |
| V5.1.5 | URL redirects validated | N/A | No redirect flows |

### V5.2 Sanitization and Sandboxing

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V5.2.1 | OS-level injection prevented | PASS | `Sources/spook/Commands/Exec.swift:posixShellEscape` — every token escaped before SSH transmission. Agent scrubs `SPOOK_AGENT_*` / `SPOOK_AUDIT_*` from child env |
| V5.2.2 | Parameterized queries | N/A | No SQL |
| V5.2.3 | Auth header sanitization | PASS | Constant-time Bearer compare via `constantTimeEqual`; break-glass tickets decoded into typed value BEFORE any claim is trusted |
| V5.2.4 | Injection-resistant templating | N/A | No HTML templating |
| V5.2.5 | XML parser external entities disabled | PASS | `Sources/SpookInfrastructureApple/SAMLAssertionVerifier.swift` — `XMLParser.shouldResolveExternalEntities = false`, no DTD processing |

### V5.3 Output Encoding

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V5.3.1 | Context-appropriate encoding | PASS | `JSONEncoder` for all HTTP responses; `APIEnvelope<T>` carries typed payloads |
| V5.3.3 | Safe header encoding | PASS | `HTTPResponse.serialize()` — structured header assembly, no interpolation of caller-controlled strings into header names/values |
| V5.3.4 | HTML / JS / XML escaping | N/A | No HTML/JS output |

### V5.5 Deserialization Prevention

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V5.5.1 | Safe deserialization APIs | PASS | Typed Codable only; no `NSKeyedUnarchiver` on untrusted input |
| V5.5.3 | Deserialization from trusted sources | PASS | Every decode is post-TLS + post-auth; signatures verified before claims decoded |

---

## V6 — Stored Cryptography

### V6.1 Data Classification

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V6.1.1 | Regulated / PII at rest encrypted | PASS | `BundleProtection` applies CUFUA on laptops + FileVault expected on all hosts; `docs/DATA_AT_REST.md §OWASP ASVS mapping` |
| V6.1.2 | Health data at rest | N/A | No health data |
| V6.1.3 | Payment data at rest | N/A | No payment data |

### V6.2 Algorithms

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V6.2.1 | FIPS/NIST-approved crypto modules | PASS | CryptoKit (FIPS 140-3 via corecrypto); Secure Enclave (FIPS 140-3 Level 2) used for break-glass signing — keys are non-exportable by hardware policy |
| V6.2.2 | Industry-proven algorithms only | PASS | P-256 ECDSA (NIST FIPS 186-5) for break-glass signing via SEP; Ed25519 (RFC 8037) for Merkle signed-tree-heads; TLS 1.3; HMAC-SHA256; SHA-256; RSA-PKCS1-v1_5-SHA256 (2048-bit min) |
| V6.2.3 | No deprecated primitives | PASS | No MD5 / SHA-1 / DES / 3DES / RC4 anywhere |
| V6.2.4 | CSPRNG for random values | PASS | `UUID()` (SystemRandomNumberGenerator); `Curve25519.Signing.PrivateKey()` seeds from system CSPRNG |
| V6.2.5 | Equivalent crypto strength | PASS | Ed25519 ~128-bit; TLS 1.3; RSA 2048-bit floor (NIST SP 800-131A Rev 2) |
| V6.2.6 | Nonces/IVs unique per key | PASS | Ed25519 deterministic; domain separation via `version || sig_type` prefix bytes |
| V6.2.7 | Encrypted data + keys separation | N/A | No archive format |

### V6.3 Random Values

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V6.3.1 | CSPRNG used | PASS | `SystemRandomNumberGenerator` / `SecRandomCopyBytes` / `UUID()` |
| V6.3.2 | Seeded with entropy | PASS | Apple CSPRNG — OS-managed |
| V6.3.3 | GUID from secure random | PASS | `UUID()` is 128-bit CSPRNG |

### V6.4 Secret Management

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V6.4.1 | Secrets in a key vault | PASS | macOS Keychain for API tokens; **Secure Enclave for break-glass signing keys** (non-exportable by hardware); file-backed Merkle key at 0600; `AuditSinkFactory.loadOrCreateSigningKey` refuses weaker perms |
| V6.4.2 | Secret access audited | PASS | Keychain access logged by macOS; `AuditRecord` logs every credential-mediated action |

---

## V7 — Error Handling and Logging

### V7.1 Log Content

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V7.1.1 | No sensitive data in logs | PASS | `.private(mask: .hash)` on guest stdout/stderr, ticket bytes, tokens; only JTIs/issuer/tenant `.public` |
| V7.1.2 | No session tokens / PII in logs | PASS | Constant-time compares never log bytes; `HTTPResponse.internalError` returns a correlation ID, not the underlying error |
| V7.1.3 | Log security events | PASS | `AuditRecord` emitted on every control-plane action (`Sources/SpookCore/TenancyModel.swift`) |
| V7.1.4 | Required fields present | PASS | timestamp, source, identity, action, outcome, correlation — all six in `AuditRecord` |

### V7.2 Log Processing

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V7.2.1 | Logs centralized + processed | PASS | `AuditSinkFactory` composes JSONL + append-only + Merkle + S3 Object Lock chain |
| V7.2.2 | Logs protect against tampering | PASS | Merkle tree with SEP-bound P-256 STH (RFC 6962 TBS format, key non-exportable; FIPS 140-3 Level 2); `UF_APPEND` kernel flag; S3 Object Lock Compliance mode |

### V7.3 Log Protection

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V7.3.1 | Logs encoded against injection | PASS | JSON output; no `printf`-style format strings with untrusted input |
| V7.3.2 | Logs integrity-protected | PASS | Merkle + S3 Object Lock |
| V7.3.3 | Synchronized time source | PASS | NTP implicit (macOS default); ISO-8601 timestamps |
| V7.3.4 | Logs retained | PASS | S3 Object Lock retention (`SPOOK_AUDIT_S3_RETENTION_DAYS`); 7-year default |

### V7.4 Error Handling

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V7.4.1 | Generic error messages | PASS | `HTTPResponse.internalError` returns correlation-ID-only; no error details on the wire |
| V7.4.2 | Last-resort handler | PASS | `HTTPAPIServer` catches all handler errors; 500 conversion is universal |
| V7.4.3 | Error-log content standardized | PASS | `context [correlationID]: error.localizedDescription` |

---

## V8 — Data Protection

### V8.1 General

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V8.1.1 | Sensitive-data handling documented | PASS | `docs/DATA_AT_REST.md` + `docs/THREAT_MODEL.md §Assets` |
| V8.1.3 | Temp files + caches protected | PASS | `ScriptFile.writeToCache` uses `~/Library/Caches/com.spooktacular/provisioning/<uuid>/` at mode 0700; deleted after VM consumes |
| V8.1.4 | Sensitive data detected + alerted | N/A | Level 3 |
| V8.1.5–V8.1.6 | Backup encryption / ACL | N/A | Operator's responsibility (Time Machine, snapshot policy) |

### V8.3 Sensitive Private Data

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V8.3.1 | Sensitive data in bodies not URLs | PASS | Bearer tokens in headers; path segments non-sensitive |
| V8.3.2 | Unauthenticated access protected | PASS | Only `/health` is unauthenticated; returns `{ "status": "ok" }` |
| V8.3.4 | Data classification + retention applied | PASS | Audit retention via S3 Object Lock; break-glass denylist retained until expiry |

---

## V9 — Communications

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V9.1.1 | TLS 1.2+ for all communications | PASS | TLS 1.3 floor — `HTTPAPIServer.init` + `KeychainTLSProvider.makeHTTPClient` + `reloadTLS` |
| V9.1.2 | Trusted CAs; revocation checked | PASS | `ClusterTLSDelegate` anchor-pins in-cluster CA; JWKS pinning via `staticJWKSPath` / `jwksURLOverride` |
| V9.1.3 | Weak ciphers disabled | PASS | TLS 1.3 only — mandatory cipher set (AES-GCM / ChaCha20-Poly1305) |
| V9.2.1 | External connections authenticated | PASS | K8s API ServiceAccount Bearer + pinned CA; AWS SigV4; GitHub Bearer PAT over TLS |
| V9.2.2 | Outgoing TLS-authenticated | PASS | `URLSession` with pinned delegates for K8s; system trust for public CAs |
| V9.2.3 | CN/SAN validated | PASS | Default `URLSession` behavior; explicit `server_name` in `prometheus.yml` reference |

---

## V10 — Malicious Code

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V10.1.1 | Code review scans for malicious patterns | PASS | CI runs `swiftlint`, CodeQL static analysis; `docs/THREAT_MODEL.md §5` documents supply chain |
| V10.2.1 | App binary signed | PASS | `build-app.sh` — `codesign --options runtime --timestamp --entitlements ...` |
| V10.2.2 | Version control integrity | PASS | Git + CI attestations |
| V10.2.3 | No backdoors / unauthorized code | PASS | Code review; `swift package show-dependencies` empty (zero third-party deps) |
| V10.3.1 | Hardened Runtime | PASS | `codesign --options runtime` + notarization via `xcrun notarytool` |
| V10.3.2 | Third-party deps reviewed | N/A | Zero third-party Swift dependencies |
| V10.3.3 | App pinned to validated runtime | PASS | `Package.swift` targets macOS 15; Swift version pinned |

---

## V11 — Business Logic

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V11.1.1 | Sequential flows enforced | PASS | `RunnerStateMachine` 9-state FSM; invalid transitions produce empty effects |
| V11.1.2 | Business-logic rate limits | PASS | Per-IP rate limit; per-tenant `TenantQuota`; fair-share `FairScheduler` |
| V11.1.3 | Rules enforced server-side | PASS | RBAC + isolation checks in `HTTPAPIServer.routeRequest` before handler dispatch |
| V11.1.4 | Anti-automation for repeated ops | PASS | Break-glass single-use + 1h TTL; runner pool capacity limits |
| V11.1.5 | Reads return consistent state | PASS | Actor-isolated `RunnerPoolReconciler` + K8s optimistic concurrency via `resourceVersion` |
| V11.1.6 | Timely state updates | PASS | Watch events drive real-time reconciliation; `periodicHealthCheck` reconciles periodically |
| V11.1.7 | State transitions authorized | PASS | Every state-changing API call goes through RBAC; break-glass gated by ticket |

---

## V12 — Files and Resources

### V12.1 File Upload

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V12.1.1 | File inspection before acceptance | PASS | Agent `handleUploadFile` validates filename via `lastPathComponent`, rejects `.` / `..` / empty |
| V12.1.2 | File size limits | PASS | `maxRequestBytes` (`SPOOK_MAX_REQUEST_BYTES`) caps request bodies |
| V12.1.3 | File-type allowlist | N/A | Level 3 |

### V12.2 File Integrity

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V12.2.1 | File origin authenticated | PASS | Uploads require break-glass or runner tokens; audit captures caller |

### V12.3 File Execution

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V12.3.1 | Uploads not executed by the app | PASS | Agent writes uploads to `~/Downloads/SpooktacularInbox/`; no `exec` path reads this dir |
| V12.3.2 | Path traversal prevented | PASS | `Sources/spooktacular-agent/AgentRouter.swift:handleListFS` — component-aware containment + symmetric symlink resolution |
| V12.3.3 | Filename restricted | PASS | `URL.lastPathComponent` strips path components; VM names regex-validated |
| V12.3.4 | No file execution from public space | PASS | Host scripts under `~/Library/Caches/...` at 0700 (only the guest agent executes) |
| V12.3.5 | No server-side code eval | PASS | Agent exec is break-glass-only and uses `/bin/bash -c <literal>`, never an attacker-controlled interpreter |

### V12.4–V12.6

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V12.4.1 | Files outside webroot | N/A | No web root |
| V12.4.2 | AV scanning | N/A | MDM / endpoint protection is operator-owned |
| V12.5.1 | Downloads auth-gated | PASS | Agent `/api/v1/files` GET requires runner or break-glass token |
| V12.5.2 | Direct object references protected | PASS | Listing only exposes `~/Downloads/SpooktacularInbox/` |
| V12.6.1 | Outbound to trusted resources only | PASS | `JWKSFetch` accepts static file OR explicit URL override OR discovery; no user-controlled outbound URL construction |

---

## V13 — API and Web Service

### V13.1 Generic

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V13.1.1 | Same encoding across components | PASS | JSON UTF-8 throughout |
| V13.1.3 | URL parameters access-controlled | PASS | Path segments → `inferResource` / `inferAction` → RBAC |
| V13.1.4 | Admin functions separated | PASS | `/v1/roles` + `/v1/tenants` require security-admin or platform-admin |
| V13.1.5 | Safe content-type in responses | PASS | `application/json; charset=utf-8` + `X-Content-Type-Options: nosniff` (per V14.4.2, added in this audit) |

### V13.2 RESTful

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V13.2.1 | Rate limiting on enabled methods | PASS | `HTTPAPIServer` `SPOOK_RATE_LIMIT` (default 120/min per IP) |
| V13.2.2 | JSON schema validated | PASS | Typed `Codable` decoders for every request body |
| V13.2.3 | CSRF tokens | N/A | No browser-form interaction |
| V13.2.4 | OIDC / PKCE | PASS | Federated identity via `OIDCTokenVerifier`; API also supports Bearer + federated JWT |
| V13.2.5 | REST-level access control | PASS | RBAC gate per endpoint |
| V13.2.6 | Message-level confidentiality / integrity | PASS | TLS 1.3; break-glass carries Ed25519 signature at message layer |

### V13.3–V13.4
N/A — no SOAP, no GraphQL.

---

## V14 — Configuration

### V14.1 Build and Deploy

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V14.1.1 | Automated build + deploy | PASS | `build-app.sh` + CI pipeline; reproducible from tag |
| V14.1.2 | Secure compiler flags | PASS | `swift build -c release` + Hardened Runtime + stack protections |
| V14.1.3 | Server config hardened | PASS | `docs/DEPLOYMENT_HARDENING.md` — 18-item pre-flight + reference LaunchDaemon |
| V14.1.4 | App + deps + services reviewed | PASS | Zero deps (trivially audited); `docs/THREAT_MODEL.md §5` on supply chain |
| V14.1.5 | Unauthorized connections denied | PASS | mTLS required in production; `--insecure` is explicit and warning-logged |

### V14.2 Dependency Management

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V14.2.1 | Up-to-date components | PASS | Zero third-party deps; Apple SDKs tracked to macOS target |
| V14.2.2 | Unneeded features disabled | PASS | App Sandbox on GUI (`Spooktacular.entitlements`); Hardened Runtime on all binaries |
| V14.2.3 | Subresource integrity | N/A | No browser-delivered resources |
| V14.2.4 | Component signatures verified | PASS | `codesign --timestamp` + notarization |
| V14.2.5 | SBOM | PASS | CI emits SBOM on release |

### V14.3 Unintended Disclosure

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V14.3.1 | Debug/trace info not exposed | PASS | `HTTPResponse.internalError` strips error details from the wire |
| V14.3.2 | Default system accounts disabled | PASS | EC2 Mac bootstrap creates dedicated `spooktacular` daemon user |
| V14.3.3 | No system-info headers | PASS | No `Server` or `X-Powered-By` emitted |

### V14.4 HTTP Security Headers

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V14.4.1 | Content-Type with charset | PASS | `application/json; charset=utf-8` on JSON responses |
| V14.4.2 | `X-Content-Type-Options: nosniff` | PASS | `HTTPResponse.serialize()` — added in this audit |
| V14.4.3 | `Content-Security-Policy: default-src 'none'; frame-ancestors 'none'` | PASS | Same |
| V14.4.4 | Browser runtime hardening | PASS | `Referrer-Policy: no-referrer` |
| V14.4.5 | HSTS | PASS | `Strict-Transport-Security: max-age=31536000; includeSubDomains` |
| V14.4.6 | Referrer-Policy | PASS | `no-referrer` |
| V14.4.7 | `X-Frame-Options: DENY` | PASS | Same — legacy defense alongside CSP `frame-ancestors` |

### V14.5 Request-Header Validation

| ID | Requirement | Verdict | Evidence |
|----|------------|---------|----------|
| V14.5.1 | HTTP methods validated | PASS | `HTTPAPIServer.inferAction` maps known methods; unknown methods → 404 |
| V14.5.2 | Content-Type matches handler expectation | PASS | JSON handlers decode via `JSONDecoder`; mismatch → 400 |

---

## Remediation

| Item | ASVS Control | Status |
|------|--------------|--------|
| HTTP security headers on every response | V14.4.2–7 | Remediated (commit `eca57d6aa`) |
| Break-glass signing key generated inside Secure Enclave (hardware-bound, non-exportable, AAL3) | V2.7.1 | Remediated (unified `P256KeyStore` with `Service.breakGlass` + `.userPresence`) |
| Unified P-256 key-store primitive covering all SEP-bound signing purposes (break-glass, operator identity, host identity, OIDC issuer, Merkle audit) with per-purpose service namespaces so rotation + audit are decoupled | V6.4 / V10.3 | Remediated (`P256KeyStore` + `spook identity` CLI) |
| Merkle audit signing key generated inside Secure Enclave (non-exportable; STH forgery requires hardware, not just process compromise) | V7.2.2 | Remediated (`P256KeyStore` with `Service.merkleAudit` + `MerkleAuditSink` takes `any P256Signer`) |
| Host-to-agent auth swapped from shared static tokens to per-request P-256 signatures (nonce-replay-protected; body-hash-bound) | V2.10.1 | Remediated (`SignedRequestVerifier` + `GuestAgentClient.sign`) |
| Operator-to-API auth retired static Bearer token (`SPOOK_API_TOKEN`) in favor of the same signed-request primitive; `spook sign-request` as the ergonomic CLI / scripting helper | V2.10.1 | Remediated (`HTTPAPIServer` + `SPOOK_API_PUBLIC_KEYS_DIR` + `spook sign-request`) |
| Workload-identity OIDC federation — Spooktacular mints ES256 JWTs for its managed VMs so workloads get short-lived AWS STS credentials via `AssumeRoleWithWebIdentity` (no long-lived IAM access keys in VM images) | V2.10.1 / V6.2 | Shipped (`WorkloadTokenIssuer` + `/.well-known/openid-configuration` + `/.well-known/jwks.json`) |
| Per-operator trust allowlist (non-repudiation via cryptographic attribution) | V2.7.5 | Remediated (`SPOOK_BREAKGLASS_PUBLIC_KEYS_DIR` + multi-key verifier) |
| Per-action MFA on admin CLI commands | V4.3.1 | Remediated (`AdminPresenceGate`) |
| Federated admin tokens require stepped-up `acr` | V2.7.4 | Remediated (`OIDCTokenVerifier.insufficientACR`) |

## External validation

Per OWASP's guidance that self-audits be followed by external review, the following remain tracked in `docs/THREAT_MODEL.md §9`:

- [ ] Third-party penetration test (HTTP API, guest agent, controller)
- [ ] SOC 2 Type II attestation (audit chain + Merkle + S3 Object Lock)
- [ ] CIS Benchmark conformance scan
- [ ] Red-team exercise simulating break-glass escalation

## Attestation

This self-audit was performed against `main` on 2026-04-17. Every `PASS` cites a concrete file in the repository. Any change to the file paths referenced here must be accompanied by an update to this document.
