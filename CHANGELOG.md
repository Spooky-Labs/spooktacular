# Changelog

All notable changes to Spooktacular are documented here.

This project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Security — Fortune 20 production hardening wave

A cross-layer hardening pass covering ~158 findings from a deep audit against a Fortune 20 reference profile. Every change is covered by tests; total suite is now 822 passing.

- **Silent-failure sweep**: every boundary that previously returned `[]` / `nil` / `false` on error now propagates a typed error, emits a metric, or writes an audit record. Includes `SetupAutomation.sequence(for:)` (now throws `.unsupportedVersion`), `OTLPHTTPJSONExporter` (bounded retry queue + metric on loss + batching), `RBACService` (new `AuthzOutcome` distinguishes deny from transient error), `ProcessRunner` (stderr captured, not `/dev/null`'d), `CloneManager` (machine-identifier.bin SHA-256 verified after write), `ScriptFile.cleanup` (keys on the file URL, not the parent dir), and nine more.
- **Fleet coordination primitives**: new `FleetSingleton` port + `DynamoDBFleetSingleton` impl eliminate per-process nonce / used-ticket caches in multi-host deployments. `TenantQuota.evaluate(pending:)` closes the cross-controller over-allocation race; new `PendingAllocationReserver` actor backs the reservation. `DistributedLockService` gains a mandatory `compareAndSwap(old:new:)` method on the protocol itself. `FileDistributedLock` switched to `O_CREAT | O_EXCL` + `fstat` inode verification (TOCTOU fix). `DynamoDBDistributedLock` validates AWS credential shape at init (`^(AKIA|ASIA)[A-Z0-9]{16}$`, printable-ASCII 16–128-byte secrets). `FairScheduler` fixed max-min weighted fair: no hungry tenant is starved when `capacity ≥ tenants`, while pure weight proportional (e.g. 3:1 at cap 8 → 6:2) is preserved when it doesn't starve anyone. `ProductionPreflight` refuses multi-tenant startup without a distributed lock service. `VMIAMBinding` throws `ttlOutOfRange` instead of silently clamping.
- **GitHub runner lifecycle end-to-end**: typed `GitHubRunnerScope` with regex validation; `IssuedTokenLedger` actor tracks registration tokens and expires them at GitHub's 1-hour TTL so revoked tokens don't linger in memory. `RunnerPoolManager` emits `PoolAction.drainRunner(name, deadline:)` that notifies GitHub, waits for in-flight jobs via polling, then deletes — no more torn builds on scale-down. `WorkloadTokenIssuer` ships real JWKS `kid` rotation with a 24h overlap window. `WorkloadTokenRefresher` actor ships complete (was a TODO); refreshes 2 minutes before expiry with exponential backoff. `spook remote install-agent <vm>` convenience subcommand copies the agent binary and runs `--install-agent` in one step. Per-label shell escape in the runner template closes a command-injection vector from malicious label input.
- **Warm-pool scrub validation**: `ScrubStrategy.validate(vm:)` now returns `RecycleOutcome` (new enum: `.readyForNextJob`, `.needsRetry(reason:)`, `.failed(reason:)`) and actually proves the guest is clean — 10-check battery covering runner processes, `/Users/runner/work`, clipboard, `/tmp`, `/var/tmp`, `~/Library/Caches`, ssh-agent, Docker/containerd/colima/podman, unexpected LaunchAgents (allowlist), unexpected TCP listeners (SSH only). `RecycleStrategy` protocol contract tightened. `VirtualMachine` now exposes `stopGracefully(timeout:)` + `stopImmediately()` so callers opt in explicitly; `stop(graceful: false)` still grants a 5s grace window before the pull-the-cord path. `SnapshotManager.save` is now atomic via a staging directory renamed on success.
- **HTTP + vsock hardening**: `HTTPAPIServer` enforces body size before trusting `Content-Length`, rejects duplicate `Content-Length` per RFC 7230 §3.3.2, tracks elapsed time from first byte (slow-loris fix), mints `X-Request-ID` on every response, ships a standard `{error:{code,message,requestId}}` envelope with 12 well-defined error codes, splits rate-limit buckets between reads and writes, and only honors `X-Forwarded-For` when operators opt in via `SPOOK_TRUST_FORWARDED_FOR=1`. Guest `AgentHTTPServer` raised vsock backlog to 64, enforces 128-connection ceiling with 503 on overflow, and sets `SO_RCVTIMEO=5s` on every accepted socket. `GuestAgentClient.request(timeout:)` races the read against a deadline via `TaskGroup`. `LaunchDaemon` plist now carries `ThrottleInterval=10` and `SoftResourceLimits` (files=256, mem=512MiB).
- **Crypto hardening**: SAML verifier fails closed on missing/malformed Conditions (no more silent time-validation skip). XML canonicalization caps entity expansions + element depth (billion-laughs defense) and preserves CDATA fidelity. OIDC verifier validates `iss` before selecting the JWKS key (cross-IdP confusion fix) and `audience` is non-optional. `FederatedIdentity.isExpired(now:)` is now injectable. `KeychainTLSProvider` verifies the cert/key actually pair by signing a nonce and validating — an imported mismatched identity no longer passes silently. `CryptoKitHMACProvider` defends against empty secrets by returning a poisoned sentinel digest. `BreakGlassTicket.isFutureIssued(now:clockSkew:)` renamed for clarity; semantics fixed. `BreakGlassVerification` maxUses is now a per-JTI counter, not single-bit. Two `as!` force-casts in `Serve.swift` replaced with `CFGetTypeID`-guarded `as?`. `AdminPresenceGate` headless bypass loophole closed: now requires two env vars AND a signed operator-consent token, writes an audit record on every bypass (refuses the bypass if no sink), and increments a counter labeled by hostname. `PinnedTLSIdentityProvider` refinement protocol makes pinning part of the contract.
- **Audit durability + verify CLI**: `AuditSink.record(_:)` protocol is now `async throws` — every adapter propagates write failures (no more silent loss). `AppendOnlyFileAuditStore` fsyncs on every append. `JSONFileAuditSink` rolls over daily at UTC midnight and on size threshold (default 1 GiB). New `spook audit verify --record <r> --audit-path <p> --tree-head <t> --public-key <k>` CLI implements RFC 6962 Merkle inclusion-proof reconstruction; signature verifier accepts both P-256 ECDSA (current signer) and Ed25519 (legacy + third-party CT compatibility). `S3ObjectLockAuditStore` HEADs after every PUT to confirm the object is under Object Lock. `HashChainAuditSink` rehydrates on startup and throws on hash-chain break.
- **K8s controller + Helm hardening**: both CRDs gained `observedGeneration` + `conditions[]` (Available / Progressing / Degraded / PoolReady / ScaleUpInProgress / CapacityExhausted) with proper `lastTransitionTime` preservation. Printer columns + status subresource. `ValidatingWebhookConfiguration` shipped with `failurePolicy: Fail` + cert-manager integration; enforces tenant-vs-namespace and sourceVM allowlists. 2-VM-per-host enforcement at both admission and reconcile. K8s watch stream gains a 60s timeout with reconnect (exponential backoff 5→10→30s) + a `watch_stream_reconnect_total` metric. Helm chart now ships `NetworkPolicy`, `PodDisruptionBudget`, `ServiceMonitor`, and `PrometheusRule` with default alerts; resource requests tuned (500m CPU / 256Mi floor, scaling rule of thumb in values comments).
- **EC2 Mac productization**: Terraform module now ships `aws_ssm_document.spooktacular_install` (was a loose YAML on disk), 7 CloudWatch alarms (`HostUtilizationHigh/Low`, `SpooktacularAPIErrors`, `VMCreationFailureRate`, `AuditExportFailure`, `TLSCertExpiry`, `ASGCapacityUnreached`), `aws_licensemanager_license_configuration`, `aws_resourcegroups_group` (HRG for Mac hosts), and an ASG lifecycle hook for drain-on-terminate backed by a new `DrainSpooktacularHost` SSM Automation runbook. `bootstrap.sh` is now idempotent (`set -Eeuo pipefail`, `mktemp -d` scratch, trap-based cleanup, `spook doctor --strict` short-circuit). Fixed a silent plaintext-token leak in the existing install doc (ProgramArguments no longer carries `--api-token`; token lives in Keychain). `docs/EC2_MAC_DEPLOYMENT.md` documents the dedicated-host → K8s-node mapping and the 24h minimum-allocation cost model.
- **Observability as code**: `docs/observability/slo-catalog.md` defines 10 user-facing + platform SLIs with PromQL, SLO target, window, and alert name for each. Two Grafana dashboards shipped as JSON (controller + fleet). `prometheus-scrape-config.yaml` with Kubernetes SD, EC2 SD, mTLS, bearer tokens, relabeling. SLO-burn-rate alert rules extended accordingly.
- **CLI + SwiftUI UX**: resumable IPSW downloads via HTTP Range + `If-Range` (4-attempt exponential backoff, SHA-256 content-addressed cache — no more 15 GB re-downloads on network blips). `spook create --json` + documented exit codes (0/1/2/3). `TerminalStyle.printJSON` + `printJSONError` helpers. `CreateVMSheet` wires all 6 accessibility IDs, shows substep progress + byte counter, surfaces a Cancel button that removes partial bundles, adds `.help()` tooltips on every control, and a bridged-network interface picker populated via `getifaddrs`. `AppState` gains `SpooktacularError` with `suggestedAction` on every case. Workspace windows now restore on app launch via `@AppStorage("openWorkspaces")`. `SidebarView` + `VMDetailView` emit dynamic VoiceOver labels + values (not just test identifiers). Menu-bar icon animates while any VM is transitioning. `⇧⌘S/H/P` keyboard shortcuts on the workspace window. AppIntents propagate errors to Shortcuts.
- **Procurement + governance docs**: added `docs/INCIDENT_RESPONSE.md` (4 full runbooks — leaked break-glass token, compromised Mac host, Merkle signing-key compromise, S3 Object Lock misconfiguration), `docs/DATA_PROCESSING_AGREEMENT.md` (GDPR Art. 28-aligned template), `docs/AUDIT_STATUS.md` (SOC 2 / ISO 27001 / FedRAMP / HIPAA / PCI posture), `docs/PATCH_POLICY.md` (CISA KEV escalation with 24h/7d/30d SLAs), `docs/EXPORT_CONTROL.md` (EAR + OFAC), `docs/VPAT.md`, `docs/SUB_PROCESSORS.md`. `SECURITY.md` gained a PGP disclosure section (with publish-your-key steps). `THREAT_MODEL.md` §4.7 adds an insider-threats STRIDE table.
- **CI hardening**: `ci.yml` now runs SwiftLint `--strict`, generates + builds the Xcode project, runs UI tests, and enforces DocC warnings-as-errors. `release.yml` generates SBOM **before** `gh release create` so scanners see it on first publish. `Doctor.swift` rewritten so `spook doctor --strict` prints `[NN]`-prefixed lines that map 1:1 to `docs/DEPLOYMENT_HARDENING.md`'s 18-item preflight; the 6 reviewer-flagged probes (SAML, IAM binding store writable, audit sink open-for-append, signed-request key material, guest-agent reachability, codesign timestamp) are all implemented.
- **Clean Architecture enforcement**: `DocConsistencyTests` now catches layer violations at build time. `SpookCore` is strictly Foundation-only (MerkleTreeVerifier relocated to `SpookApplication` which may import CryptoKit); `SpookApplication` imports Foundation / SpookCore / CryptoKit only (all direct `import os` replaced with injected `LogProvider`).

### Security — earlier in cycle
- **Time-limited, single-use break-glass tickets** per NIST SP 800-53 AC-14, OWASP ASVS V2.10, and SOC 2 CC6.6. `BreakGlassTicket` value type signed with Ed25519 (RFC 8037). Compact `bgt:<base64url-payload>.<base64url-sig>` wire format with no `alg` header — eliminates JWT's algorithm-confusion attack surface rather than guarding against it. `UsedTicketCache` enforces single-use via an atomic JTI denylist; OWASP JWT Cheat Sheet rules documented inline. New `spook break-glass keygen` + `spook break-glass issue` CLI. Agent loads verifier via `SPOOK_BREAKGLASS_PUBLIC_KEY` / `_ISSUERS` / `_TENANT` env vars. Four-gate server-side enforcement: port-tier, credential-path selection, credential check, handler-tier re-assertion. 15 new tests.
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

## [1.0.1] - 2026-04-19

### Added — GUI ↔ CLI feature parity

Closes the parity gap between the SwiftUI app and the `spook` CLI. All five
features ship behind Apple framework APIs cited inline in the code.

- **SSH into workspaces from the toolbar.** The running-workspace toolbar's
  "Copy IP" button is now a `Menu(primaryAction:)` split-button: primary tap
  copies the DHCP-resolved IPv4 to the pasteboard; the chevron opens the
  host's default `ssh://` handler (Terminal.app on stock macOS, iTerm2 / Warp
  if registered) with a session to `admin@<ip>`. Mirrors `spook ssh`. (#39)
- **Local IPSW file picker in Create.** New "macOS Source" segmented picker
  (Latest compatible | Local IPSW file) closes parity with
  `spook create --from-ipsw <path>`. Skips the 10–20 GB Apple download when
  the operator has a cached IPSW on disk — critical for offline installs and
  re-creating VMs from a pinned build. Uses `UTType(filenameExtension: "ipsw")`
  to scope the `NSOpenPanel` to IPSW files. (#40)
- **Provisioning template picker in Create.** Menu picker with five choices:
  None / GitHub Actions Runner / OpenClaw AI Agent / Remote Desktop (VNC) /
  Custom Script. Replaces the previously-dangling user-data field that
  silently dropped scripts on the floor. GitHub runner tokens come from the
  macOS Keychain only (service `com.spooktacular.github`) per the pre-1.0
  single-protected-path principle — env-var / flag / file-path resolvers
  were removed. (#41)
- **Clone VM sheet.** Context-menu "Clone…" now opens a proper sheet with a
  name field preseeded to a free slot (`source-clone`, `-2`, `-3`, …),
  keyboard shortcut ⌘D (Finder's Duplicate convention), and disabled-state
  handling for blank / duplicate names. Replaces the silent auto-suffix
  clone that forced a second rename pass. Uses APFS copy-on-write via
  `CloneManager.clone(source:to:)`. (#42)
- **Shared folders post-creation in HardwareEditor.** Add, remove, and
  toggle read-only on each VirtIO FS mount while the VM is stopped. Closes
  parity with post-creation `spook share`. Form is already
  `.disabled(isRunning)` per Apple's
  `VZVirtualMachineConfiguration` contract ("device configuration is
  immutable after startup"), so the running-hint banner already covers the
  greyed-out state. (#43)

### Fixed
- CreateVMSheet previously stored `userDataPath` / `provisioningMode` in
  `@State` but never fed them into `createVM()` — a user-data script
  selected in the sheet would silently do nothing. Now injected via the
  same `DiskInjector` code path as `spook create`. (#41)

## [1.0.0] - 2026-04-19

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

[Unreleased]: https://github.com/Spooky-Labs/spooktacular/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Spooky-Labs/spooktacular/releases/tag/v1.0.0
