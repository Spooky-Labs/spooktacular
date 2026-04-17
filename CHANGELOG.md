# Changelog

All notable changes to Spooktacular are documented here.

This project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security
- **5-batch security hardening pass** closing all findings from successive enterprise audits:
  - Batch 1 (auth/authz): fixed CWE-862 in `FederatedAuthorization`, added `role:*` + `break-glass:invoke` permissions, TLS 1.3 floor on every NWProtocolTLS.Options site, closed K8s CA fallback silent trust, constant-time Bearer token comparison in guest agent
  - Batch 2 (OIDC/SAML): `nbf` validation with 60s skew, unconditional audience, RSA 2048-bit minimum (NIST SP 800-131A), `SAMLReplayCache`, empty-modulus guard
  - Batch 3 (injection/traversal): SSH exec command POSIX-escaping, `fsAllowedRoots` containment check with symlink resolution, VM name regex validation everywhere, agent HTTP Content-Length enforcement, log-injection sanitization
  - Batch 4 (audit correctness): RFC 6962 STH format (version byte + signature_type + ms timestamp + size + root), preserved record id/timestamp across sinks, S3 Object Lock `shutdown()` flush
  - Batch 5 (secret hygiene): signing-key `open(2) O_CREAT|O_EXCL|O_NOFOLLOW, 0600` atomic creation, agent exec env scrub (`SPOOK_AGENT_*` / `SPOOK_AUDIT_*`), VsockProvisioner stdout/stderr `.private` logging, `codesign --timestamp` flag, `SpookCLI.entitlements` app-sandbox explicit, SecKey/SecIdentity CFGetTypeID guards replacing blind force casts, SIGKILL escalation after SIGTERM on agent exec timeouts
- **VM bundle data-at-rest protection** — `BundleProtection` applies `FileProtectionType.completeUntilFirstUserAuthentication` (CUFUA) to VM bundles on portable Macs; desktops stay at `.none` so pre-login LaunchDaemons keep working. Covers OWASP ASVS V6.1.1 / V6.4.1 / V14.2.6. Inheritance propagates through every bundle write (`create`, `writeSpec`, `writeMetadata`, `clone`, `snapshot save`) and is verified by `BundleProtection.verifyInheritance` + `spook doctor --strict`. IOKit detects laptops via `IOPSCopyPowerSourcesInfo`; form-factor override via `SPOOK_BUNDLE_PROTECTION` env var or GUI Settings → Security tab (`@AppStorage`-backed). New `spook bundle protect [--all|--none]` migration CLI.
- **GitHub PAT → Keychain** path: `spook create --github-token-keychain <account>` reads from service `com.spooktacular.github`. Resolution priority: file > Keychain > env > flag (dev-only with warning). `--github-token-file` supports Vault/1Password/SSM injection.
- **Provisioning-script hardening**: `ScriptFile.writeToTempDirectory` → `ScriptFile.writeToCache` under `~/Library/Caches/com.spooktacular/provisioning/<uuid>/` with directory + file mode 0700 (was `/tmp` + 0755). New `ScriptFile.cleanup(scriptURL:)` called via `defer` after VM consumes the script; host-side window shrinks from "host lifetime" to "command duration."
- **JWKS pinning**: `OIDCProviderConfig.staticJWKSPath` loads JWKS from on-disk JSON; `jwksURLOverride` skips discovery for operators fronting the IdP with their own PKI. Three-tier resolution (static > override > discovery) in `OIDCTokenVerifier.fetchJWKS`.
- **Break-glass defense-in-depth**: `handleExec(request:authTier:)` asserts `.breakGlass` at handler boundary in addition to port-tier and token-tier gates; a routing regression or custom vsock client can't escalate without a matching break-glass token.
- **Sanitized 500s**: `HTTPResponse.internalError(correlationID:)` returns `"Internal error. Correlation ID: <uuid>"` instead of raw `error.localizedDescription`; operators pivot to logs via the ID without `SecItem`/`NWError`/filesystem-path leakage to callers.
- **RBAC persistence by default**: `JSONRoleStore` now defaults to `~/.spooktacular/rbac.json` when `SPOOK_RBAC_CONFIG` is unset; `assign()`/`revoke()` atomic-write back to disk. Previously runtime role assignments evaporated on restart. Opt-out via `SPOOK_RBAC_CONFIG=""`.
- **K8s TLS pinning for reconciler**: `RunnerPoolReconciler` now shares `KubernetesClient.session` (CA-pinned via `ClusterTLSDelegate`) instead of an unpinned `URLSession(.ephemeral)`. ServiceAccount token no longer ships over unpinned TLS.

### Added
- **Production preflight** (`ProductionPreflight.validate()`) refuses to start in production without an audit sink regardless of tenancy mode; rejects `--insecure` in multi-tenant.
- **Distributed lock factory** with DynamoDB Global Tables (`SPOOK_DYNAMO_TABLE`), Kubernetes Lease (`SPOOK_K8S_API`), or file-based (`SPOOK_LOCK_DIR`) backends. Cross-region coordination for EC2 Mac fleets.
- **S3 Object Lock audit sink** — `S3ObjectLockAuditStore` with hand-rolled SigV4 (no AWS SDK) and WORM retention.
- **Admin REST API** — `GET/POST/PATCH/DELETE /v1/tenants` and `/v1/roles` runtime management, RBAC-gated.
- **Shared SigV4 signer** — `SigV4Signer` deduplicates ~60 LOC across `S3ObjectLockAuditStore` and `DynamoDBDistributedLock`.
- **Typed Codable** throughout: `Lease` (K8s), `JWTHeader` / `JWTClaims` / `JWTAudience` / `JWK` / `JWKSDocument` (OIDC), `DDBAttribute` / `PutItemRequest` / `DeleteItemRequest` (DynamoDB). Replaces ~80 LOC of `as? [String: Any]` guards; schema drift surfaces as decoding errors.
- **Fair scheduler** (`FairScheduler` + `TenantSchedulingPolicy`) — weighted max-min fair-share allocator for VM slots. Prevents "one tenant took everything" starvation on busy multi-tenant fleets. Minimum guarantees, weight-proportional splits, maxCap ceilings; deterministic, work-conserving, monotone.
- **`spook doctor --strict`** runs 11 production-control checks (mTLS CA, RBAC config, IdP config, audit JSONL writability, UF_APPEND kernel flag, Merkle signing-key perms, lock backend, tenancy mode, `SPOOK_INSECURE_CONTROLLER` off, Hardened Runtime + Team ID, bundle protection inheritance).
- **`recoverySuggestion` on every production `LocalizedError`** — OIDCError, SAMLError, LockError, DynamoDBLockError, S3AuditError, AppendOnlyError, AuditSinkError, IdPError, ControllerError, RecycleError, GitHubServiceError, IntentError, TenantRegistryError, XMLCanonicalizationError, GitHubTokenError, ProductionPreflightError.
- **`docs/THREAT_MODEL.md`** — STRIDE per asset, supply-chain + side-channel sections, external validation checklist (pen-test, SOC 2, CIS).
- **`docs/DEPLOYMENT_HARDENING.md`** — 18-item pre-flight checklist, reference LaunchDaemon plist, verification commands, rotation/drill cadence.
- **`docs/DATA_AT_REST.md`** — OWASP ASVS mapping for the CUFUA plan, threat-model table, verification checklist.
- **`docs/observability/`** — Prometheus scrape config (mTLS-authenticated), 8-rule alerts file with runbook links, Grafana dashboard JSON (4 rows × 15 panels).

### Changed
- **Apple-API modernization**: `String.expandingTilde` replaces 8× `NSString(string:).expandingTildeInPath`; `URL.parentPath` replaces 6× `(path as NSString).deletingLastPathComponent`; `Date.ISO8601FormatStyle` replaces 8× `ISO8601DateFormatter()` allocations; `Regex` replaces `NSRegularExpression`; `URL(filePath:)` replaces `URL(fileURLWithPath:)`; `Data(contentsOf:)` replaces `FileManager.contents(atPath:)` for error-differentiated reads.
- **Env-var reconciliation**: `SPOOK_TLS_CERT_PATH` / `SPOOK_TLS_KEY_PATH` / `SPOOK_TLS_CA_PATH` are canonical (legacy un-prefixed aliases accepted); `SPOOK_AUDIT_S3_RETENTION_DAYS` is canonical (legacy `SPOOK_AUDIT_S3_LOCK_DAYS` accepted). Controller fault message aligned with docs.
- **~900 LOC dead-code removal**: `FIPSKeyStore.swift`, `MacOSGroupAuthorization.swift`, `SecretStore.swift` + `KeychainSecretStore.swift`, plus orphaned `FederatedAuthorization`, `IdPRegistry`, `RunnerGroupID`, `ProvisioningMode.recommended()`, `AuditSinkFactory.fromEnvironment()`, `GitHubRunnerService.listRunners`, `VsockProvisioner.encodeFrame`/`decodeExitCode`.

### Fixed
- `spook serve` now reads `SPOOK_TLS_CERT_PATH` / `SPOOK_TLS_KEY_PATH` as env fallbacks so the documented LaunchDaemon plist actually produces a TLS listener (was silently binding plaintext).
- Path-traversal via `hasPrefix` in `handleListFS` — replaced with component-aware containment + symmetric symlink resolution. A sibling directory (e.g. `/Users/administrator`) no longer escapes `/Users/admin` allow-list.
- Kubernetes API calls from `RunnerPoolReconciler` were bypassing `ClusterTLSDelegate`'s pinned CA — now share the pinned session.
- OIDC `buildRSAPublicKeyDER` force-unwrap on empty modulus (DoS) — guarded with INTEGER 0 fallback.
- SSTP force casts on `SecKey` / `SecIdentity` replaced with `CFGetTypeID` guards.

### Added
- Rich guest agent with 12 HTTP endpoints (clipboard, exec, apps, files, ports, health)
- Rich guest agent with 12 HTTP endpoints (clipboard, exec, apps, files, ports, health)
- `spook remote` CLI command for guest agent interaction
- GuestAgentClient actor for host-side guest API
- KeyboardDriver protocol (SpooktacularKit no longer imports AppKit)
- MACAddress value type with validation and Codable support
- ProcessRunner shared async-safe process execution
- NetworkMode proper Codable with backward-compatible decoder
- HTTP API Bearer token authentication (`SPOOK_API_TOKEN`)
- VM name validation (path traversal protection)
- Kubernetes leader election via Lease API
- Kubernetes finalizers for resource cleanup
- Atomic snapshot restore via temp file + replaceItem
- machine-identifier.bin included in snapshots
- Graceful stop with 30s timeout then force-stop escalation
- VirtualMachine.lastError for surfacing VZ errors
- Network disconnect delegate implementation
- Separate SpookCLI.entitlements (no app-sandbox for CLI)
- Liquid Glass UI across entire GUI (macOS 26+)
- RunnerPool reconciliation with lifecycle state machine (9 states: idle, provisioning, registering, ready, busy, completing, recycling, draining, terminated)
- GitHub webhook integration (HMAC-SHA256 verified `workflow_job` events for real-time job detection)
- Three-tier pool recycling strategies (reclone: fresh APFS clone, snapshot: restore to clean snapshot, scrub: in-place cleanup)
- Clean Architecture restructure (Entities / UseCases / Interfaces / Infrastructure layers)
- mTLS support for controller-to-node traffic (optional, enabled via `--mtls-ca`)
- Keychain-based secret storage (API tokens and TLS keys stored in macOS Keychain)
- Three-tier guest agent authorization (read-only, runner, break-glass token scopes)
- TLS certificate hot reload (zero-downtime cert rotation via file watching)
- OSSignposter lifecycle tracing (structured os_signpost intervals for VM and runner lifecycle)
- CodeQL static analysis, SBOM generation, and artifact attestations in CI
- EC2 Mac enterprise mode (Host Resource Group placement, drain procedures, IMDS identity verification)
- Automated doc consistency test suite (verifies docs match code for test counts, feature claims, and API surface)

### Fixed
- Notarization uses `xcrun notarytool` (Fastlane wrapper broken)
- `launchctl bootstrap/bootout` replaces deprecated `load/unload`
- `systemsetup -setremotelogin` replaced with `launchctl bootstrap`
- DiskInjector defer moved before throw point
- VsockProvisioner read is async (no main thread blocking)
- SSHExecutor uses terminationHandler (no thread pool blocking)
- Stale PID files proactively cleaned during capacity scan
- IPSW cache integrity check (zero-byte files re-downloaded)
- Ephemeral cleanup requires stale PID (not missing PID)
- Stop timeout exits non-zero
- Delete --force verifies kill succeeded
- ServicePlist XML-escapes all interpolated values
- Guest agent verifies host CID on vsock connections
- GitHub runner template uses JSON parsing (not grep)
- Codesign: inner-first order, hardened runtime, no --deep
- Version injected from git tag into Info.plist

### Changed
- CI triggers on PRs only; Beta triggers on merge to main
- Release workflow notarizes and staples before publishing
- HTTPAPIServer split into HTTPRequest, HTTPResponse, APIModels
- 411+ tests in 50+ suites (was 297 in 36)

## [0.1.0] - 2026-04-13

### Added
- Initial release
- VM creation from IPSW restore images
- APFS copy-on-write cloning (48ms)
- Full VM lifecycle (start/stop/pause/resume/save/restore)
- Unattended Setup Assistant automation (macOS 15 + 26)
- SSH provisioning with streaming output
- Disk-inject provisioning (zero-network LaunchDaemon)
- VirtIO socket provisioning with guest agent
- GitHub Actions runner, remote desktop, OpenClaw templates
- Ephemeral runners (auto-destroy on stop)
- Disk-level snapshots (save/restore/list/delete)
- 2-VM capacity enforcement
- HTTP REST API (9 endpoints)
- Kubernetes operator (MacOSVM CRD, Swift controller, Helm chart)
- 14 CLI commands
- SwiftUI GUI with Liquid Glass
- Menu bar extra
- Full VoiceOver accessibility
- NAT, bridged, isolated networking
- Metal GPU displays, audio, shared folders
- Per-VM LaunchDaemon services

[Unreleased]: https://github.com/Spooky-Labs/spooktacular/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Spooky-Labs/spooktacular/releases/tag/v0.1.0
