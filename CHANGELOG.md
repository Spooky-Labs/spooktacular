# Changelog

All notable changes to Spooktacular are documented here.

This project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Checkpoint — Guest Tools replatform (in progress)

The in-guest companion is being rebuilt around a SPICE serial-channel
clipboard bridge (`SpooktacularGuestTools`) instead of the earlier
vsock HTTP guest agent. This work is mid-flight; the previous
agent's HTTP surface was removed as part of the descope below and
has not yet been fully replaced.

### Descope — compliance fiction and unshipped subsystems removed

An honest look at this repo's history found several subsystems that
were fully implemented in source but never had a real deployment,
buyer, or maintenance owner behind them, plus a full tier of
enterprise-compliance documentation (SOC 2 / ISO 27001 / FedRAMP /
HIPAA / PCI posture, DPA, sub-processors, export control, patch
policy, VPAT, threat model, incident response, OWASP ASVS audit)
written for a company that does not exist. Both were removed rather
than left to rot:

- **NEFilterDataProvider egress firewall** — removed (~1.7k LOC).
- **Embedded Apple MDM server** — removed (~4.4k src + 3.2k test LOC).
- **Kubernetes operator, CRDs, Helm chart, K8s lease lock** — removed (~8k LOC). `FairScheduler` (the weighted max-min tenant allocator) survives as a tested, standalone algorithm not currently wired into a runtime orchestrator.
- **Guest-agent HTTP/vsock RPC surface** (`spook remote`, `GuestAgentClient`, the 12-endpoint guest HTTP API) — removed (~6.5k LOC). The SPICE clipboard bridge is the surviving in-guest integration.
- **SAML/OIDC federated-login verification stack**, including the hand-rolled XML canonicalizer — removed (~3.3k LOC). `WorkloadTokenIssuer` (Spooktacular acting as an OIDC *issuer* for AWS/GCP/Azure workload-identity federation) is a distinct, surviving feature — it was never part of the removed verifier stack.
- **Hand-rolled AWS clients, Merkle-tree/S3-Object-Lock audit tier, DynamoDB distributed lock** — removed (~4.5k LOC). Audit logging survives as OSLog + local JSONL + kernel `UF_APPEND`; distributed locking survives as a single `flock(2)`-based file backend.
- **Compliance-fiction docs**: `docs/{AUDIT_STATUS,DATA_PROCESSING_AGREEMENT,SUB_PROCESSORS,EXPORT_CONTROL,PATCH_POLICY,VPAT,DISASTER_RECOVERY,INCIDENT_RESPONSE,THREAT_MODEL,OWASP_ASVS_AUDIT}.md` and the `docs/superpowers/` planning artifacts (which had been accidentally published to spooktacular.app) are deleted. `SECURITY.md`, `docs/DEPLOYMENT_HARDENING.md`, `docs/EC2_MAC_DEPLOYMENT.md`, and the observability kit were trimmed to describe only what ships today.

Full test suite remains green throughout (750/750 at time of writing). `spook doctor --strict` now reports the smaller, real set of production controls — see `docs/DEPLOYMENT_HARDENING.md` for the current 1:1 mapping.

### Security — still shipping from this cycle

The subsystems above were removed, but the surrounding hardening
work that doesn't depend on them stays:

- **Time-limited, single-use break-glass tickets** — `BreakGlassTicket` signed with P-256 ECDSA, Secure-Enclave-bound per-operator keys, single-use via `UsedTicketCache`'s JTI denylist. `spook break-glass keygen` + `spook break-glass issue` CLI.
- **VM bundle data-at-rest protection (CUFUA)** — `BundleProtection` applies `FileProtectionType.completeUntilFirstUserAuthentication` to VM bundles on portable Macs; desktops stay at `.none`. See `docs/DATA_AT_REST.md`.
- **GitHub PAT via Keychain only** — `spook create --github-token-keychain <account>` reads from service `com.spooktacular.github`. Env-var, CLI-flag, and file-path resolution paths were removed by design.
- **Provisioning-script hardening** — scripts stage under `~/Library/Caches/com.spooktacular/provisioning/<uuid>/` at mode 0700 and are cleaned up via `defer` once the VM consumes them.
- **RBAC persistence by default** — `JSONRoleStore` defaults to `~/.spooktacular/rbac.json`; role assignments survive a restart.
- **Sanitized error responses** — `HTTPResponse.internalError(correlationID:)` returns a correlation ID, not the raw error, to API callers.
- **Workload-identity OIDC issuer** — `WorkloadTokenIssuer` mints short-lived ES256 JWTs a VM can present to `sts:AssumeRoleWithWebIdentity` (or equivalent) for scoped cloud credentials, independent of the removed login-verification stack.
- **`spook doctor --strict`** rewritten to project the current, smaller set of production controls 1:1 against `docs/DEPLOYMENT_HARDENING.md` — see that doc for the exact item list.

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
