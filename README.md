<div align="center">
  <img src="Resources/AppIcon.svg" width="128" height="128" alt="Spooktacular — Two ghosts dancing by a campfire">

  # Spooktacular

  **Double your Mac capacity. Same hardware.**

  macOS Virtualization for Teams on Apple Silicon. Run 2 VMs per Mac —<br>
  the maximum Apple's EULA allows. Clone in 48ms. MIT licensed, $0 forever.

  [![CI](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml/badge.svg)](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml)
  [![License: MIT](https://img.shields.io/badge/License-MIT-a78bfa.svg)](LICENSE)
  [![Swift 6](https://img.shields.io/badge/Swift-6.2-a78bfa.svg)](https://swift.org)
  [![macOS 26+](https://img.shields.io/badge/macOS-26+-a78bfa.svg)](https://developer.apple.com/macos/)
  [![Tests](https://img.shields.io/badge/Tests-750_passing-22c55e.svg)](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml)

  [Website](https://spooktacular.app) · [Get Started](#quick-start) · [Build from Source](#building-from-source) · [API Docs](https://spooktacular.app/api/documentation/spooktacularkit/)

</div>

---

## Why Spooktacular

- **2 VMs per Mac** — The maximum Apple's [EULA (Section 2B(iii))](https://www.apple.com/legal/sla/) allows, enforced at the kernel level. Every Mac mini, Mac Studio, or Mac Pro becomes two workloads.
- **48ms clones** — APFS copy-on-write duplicates a 64GB VM in milliseconds. No disk copy, no waiting.
- **Everything that needs a Mac** — CI/CD runners, iOS/macOS code signing, remote desktops, computer-using AI agents.
- **$0 forever** — MIT licensed. No sales calls. No per-core fees. Audit every line of [source code](https://github.com/Spooky-Labs/spooktacular).

### Why not something else?

| Tool | Strength | Where Spooktacular fits instead |
|------|----------|-----------------------------------|
| **[Tart](https://tart.run)** | Lightweight CLI for single-host VM workflows, great for local dev. | Spooktacular adds multi-tenant RBAC with tenant quotas, mTLS-secured control plane, workload-identity federation to cloud IAM (AWS/GCP/Azure), Secure-Enclave-backed break-glass access, and append-only audit logging for team fleets. |
| **[Multipass](https://canonical.com/multipass)** | Canonical's Ubuntu VM manager — Linux guests only. | macOS guests, signed-build CI, iOS simulators, Xcode toolchains — Multipass can't run any of these. |
| **[UTM](https://mac.getutm.app)** | Excellent desktop GUI for exploring macOS/Linux guests. | UTM is for one-human-at-a-keyboard. Spooktacular adds an HTTP control-plane API, GitHub Actions webhook-driven runner templates, and headless/ephemeral runner lifecycles. |
| **[Anka](https://veertu.com/anka-build/)** | Commercial cluster manager for macOS CI. | Spooktacular is free and MIT, uses Apple's Virtualization.framework (no kernel extension), and ships the same control-plane security stack (mTLS, RBAC, signed requests) out of the box. |
| **[Orbstack](https://orbstack.dev)** | Fast macOS container + Linux VM runtime. | Complements Spooktacular — Orbstack for containers on the host, Spooktacular for a full macOS VM fleet. |

## Screenshots

<div align="center">
<table>
<tr>
<td align="center"><strong>SwiftUI App (Liquid Glass)</strong></td>
<td align="center"><strong>CLI — 28 commands</strong></td>
</tr>
<tr>
<td><em>Screenshot coming soon</em></td>
<td>

```
$ spook list
NAME        STATUS   CPU  MEM   IP
base        stopped   8   16G   —
runner-01   running   8   16G   192.168.64.3
runner-02   running   8   16G   192.168.64.4
```

</td>
</tr>
</table>
</div>

## Quick Start

```bash
# Install (build from source today — see "Building from Source" below;
# signed releases will ship to this repo's Releases page)
git clone https://github.com/Spooky-Labs/spooktacular.git
cd spooktacular
./build-app.sh release

# Store the runner registration token in the Keychain — the only
# accepted way to supply it (never a flag, env var, or file path)
security add-generic-password -s com.spooktacular.github \
  -a your-org -w ghp_xxx -U

# Create a macOS VM configured as an ephemeral GitHub Actions runner.
# --from-ipsw latest (the default) downloads the newest compatible
# macOS restore image; `create` only stages the runner-registration
# script — `start` boots the VM and runs it. `--ephemeral` is needed
# on BOTH: on `create` it registers the runner as ephemeral with
# GitHub, on `start` it auto-destroys the VM bundle once it stops.
spook create runner-01 --github-runner --github-repo your-org/repo \
  --github-token-keychain your-org --ephemeral
spook start runner-01 --headless --ephemeral
```

`spook clone` (APFS copy-on-write, ~48ms) duplicates any existing VM bundle
for other workloads — see [Features](#features) below. Cloning doesn't yet
carry forward `--github-runner` template state, so a second runner today
means a second `create --github-runner` + `start`.

## Architecture

```
┌──────────────────────────────────────────────────┐
│                 SpooktacularCore                 │
│  Domain types · Protocols · Policies             │
│  TenancyModel · RunnerStateMachine               │
│  AuthorizationContext · ReusePolicy              │
└─────────────────────────┬────────────────────────┘
                         │
┌─────────────────────────▼────────────────────────┐
│             SpooktacularApplication              │
│  Use cases · Ports · Orchestration               │
│  RunnerPoolManager · GitHubRunnerTemplate        │
│  WebhookSignatureVerifier · TenantQuota          │
└─────────────────────────┬────────────────────────┘
                         │
┌─────────────────────────▼────────────────────────┐
│         SpooktacularInfrastructureApple          │
│  VZ* · Network · Security · CryptoKit            │
│  HTTPAPIServer · AgentEventListener              │
│  KeychainTLSProvider · ProcessRunner             │
└────────────┬────────────────────────┬────────────┘
            │                        │
        ┌───────┐               ┌─────────┐
        │ spook │               │   GUI   │
        │ (CLI) │               │(SwiftUI)│
        └───────┘               └─────────┘
```

Clean Architecture with compiler-enforced boundaries (checked in CI —
`DocConsistencyTests`). SpooktacularCore imports Foundation only.
SpooktacularApplication depends on SpooktacularCore (plus CryptoKit/os) only.
Infrastructure wraps Apple frameworks.

## Features

| Feature | Source | Description |
|---|---|---|
| VM Creation | [`RestoreImageManager.swift`](Sources/SpooktacularInfrastructureApple/RestoreImageManager.swift) | Auto-download latest compatible macOS IPSW, install |
| APFS Cloning | [`CloneManager.swift`](Sources/SpooktacularInfrastructureApple/CloneManager.swift) | Copy-on-write clone with new MachineIdentifier |
| VM Lifecycle | [`VirtualMachine.swift`](Sources/SpooktacularInfrastructureApple/VirtualMachine.swift) | Start, stop, pause, resume, save/restore state |
| Setup Assistant | [`SetupAutomationExecutor.swift`](Sources/SpooktacularInfrastructureApple/SetupAutomationExecutor.swift) | Unattended keyboard automation (macOS 15 + 26) |
| SSH Provisioning | [`SSHExecutor.swift`](Sources/SpooktacularInfrastructureApple/SSHExecutor.swift) | Wait for SSH, execute scripts with streaming output |
| Disk-Inject | [`DiskInjector.swift`](Sources/SpooktacularInfrastructureApple/DiskInjector.swift) | Mount guest disk, inject LaunchDaemon — zero network |
| Templates | [`GitHubRunnerTemplate.swift`](Sources/SpooktacularApplication/GitHubRunnerTemplate.swift) | GitHub Actions, remote desktop, OpenClaw — auto-execute |
| Ephemeral Runners | [`Start.swift`](Sources/spooktacular-cli/Commands/Start.swift) | `--ephemeral` auto-destroys VM on stop |
| Snapshots | [`SnapshotManager.swift`](Sources/SpooktacularInfrastructureApple/SnapshotManager.swift) | Save, restore, list, delete disk-level snapshots |
| Capacity Check | [`CapacityCheck.swift`](Sources/SpooktacularInfrastructureApple/CapacityCheck.swift) | Enforces 2-VM kernel limit with actionable errors |
| HTTP API | [`HTTPAPIServer.swift`](Sources/SpooktacularInfrastructureApple/HTTPAPIServer.swift) | 27 REST endpoints, TLS support, bearer token auth |
| Service | [`ServicePlist.swift`](Sources/SpooktacularApplication/ServicePlist.swift) | Per-VM LaunchDaemon for headless servers |
| Networking | [`VirtualMachineConfiguration.swift`](Sources/SpooktacularInfrastructureApple/VirtualMachineConfiguration.swift) | NAT, bridged, isolated |
| Accessibility | GUI sources | Full VoiceOver: labels, hints, identifiers, announcements |

## CLI Reference

| Command | Description |
|---|---|
| `spook create` | Create a new macOS VM from an IPSW restore image |
| `spook start` | Start a VM |
| `spook stop` | Stop a running VM |
| `spook suspend` | Suspend a running VM to disk |
| `spook discard-suspend` | Delete the saved-state file for a stopped VM |
| `spook stream` | Subscribe to a running VM's live event stream |
| `spook socket` | Print the Unix-domain-socket path for a running VM |
| `spook list` | List all VMs |
| `spook clone` | Clone a VM (instant copy-on-write, ~48ms) |
| `spook delete` | Delete a VM and all its data |
| `spook ip` | Show the IP address of a running VM |
| `spook set` | Modify a VM's configuration |
| `spook get` | Show a VM's configuration |
| `spook snapshot` | Manage VM disk snapshots (save/restore/list/delete) |
| `spook share` | Manage shared folders for a VM |
| `spook ssh` | SSH into a running VM |
| `spook exec` | Execute a command inside a running VM |
| `spook service` | Manage per-VM LaunchDaemons |
| `spook serve` | Start the HTTP API server |
| `spook doctor` | Check if this Mac is ready to run VMs |
| `spook rbac` | Manage roles and role assignments |
| `spook bundle` | Bundle-level maintenance: protect, import, export |
| `spook break-glass` | Issue and manage emergency-access tickets |
| `spook iam` | Bind VMs to cloud IAM roles (AWS / GCP / Azure) |
| `spook identity` | Manage SEP-bound signing keys (operator, host, OIDC) |
| `spook sign-request` | Sign an HTTP request for the operator-to-API auth scheme |
| `spook security-controls` | Print an inventory of shipped security controls with code references |
| `spook rosetta` | Rosetta 2 utilities for Linux guests |

## HTTP API

```bash
spook serve --port 8484 --host 127.0.0.1
```

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | Unauthenticated health check |
| `GET` | `/metrics` | Prometheus metrics (authenticated) |
| `GET` | `/.well-known/openid-configuration` | OIDC discovery document (when workload-identity federation is configured) |
| `GET` | `/.well-known/jwks.json` | Public JWKS for OIDC federation |
| `GET` | `/v1/vms` | List all VMs |
| `POST` | `/v1/vms` | Create a VM |
| `GET` | `/v1/vms/:name` | Get VM details |
| `DELETE` | `/v1/vms/:name` | Delete a VM |
| `POST` | `/v1/vms/:name/clone` | Clone from a base VM |
| `POST` | `/v1/vms/:name/start` | Start a VM |
| `POST` | `/v1/vms/:name/stop` | Stop a VM |
| `GET` | `/v1/vms/:name/ip` | Resolve VM IP |
| `GET` | `/v1/vms/:name/identity-token` | Mint a workload-identity OIDC token for the VM |
| `GET` | `/v1/roles` | List all roles |
| `GET` | `/v1/roles/:actor` | List role assignments for an actor |
| `POST` | `/v1/roles/assign` | Assign a role to an actor |
| `POST` | `/v1/roles/revoke` | Revoke a role from an actor |
| `GET` | `/v1/tenants` | List all tenants |
| `POST` | `/v1/tenants` | Create a tenant |
| `GET` | `/v1/tenants/:id` | Get a tenant |
| `PUT`/`PATCH` | `/v1/tenants/:id` | Replace a tenant |
| `DELETE` | `/v1/tenants/:id` | Remove a tenant |
| `GET` | `/v1/iam` | List all VM → IAM role bindings |
| `GET` | `/v1/iam/:tenant` | List bindings for a tenant |
| `GET` | `/v1/iam/:tenant/:vm` | Get one binding |
| `PUT` | `/v1/iam/:tenant/:vm` | Upsert a binding |
| `DELETE` | `/v1/iam/:tenant/:vm` | Remove a binding |

## EC2 Mac Quickstart

Turn one EC2 Mac Dedicated Host into two schedulable macOS worker slots.
[`deploy/ec2-mac/`](deploy/ec2-mac/README.md) ships a Terraform module (Dedicated
Host + instance provisioning), an SSM install document, and a bootstrap script
for the full walkthrough — see [`deploy/ec2-mac/README.md`](deploy/ec2-mac/README.md).

Once a host is bootstrapped:

```bash
spook doctor
# ✓ Apple Silicon (arm64)
# ✓ macOS 15.4.0
# ✓ Disk space: 234 GB free
# ✓ Base VM found: base
# ✓ Capacity: 0/2 VMs running
```

## Security

Spooktacular supports **single-tenant** and **multi-tenant** deployment modes:

- **Mandatory mTLS** in production — the control plane refuses to start without TLS certificates (TLS 1.3 floor, hot-reloadable)
- **Hardware-bound break-glass signing via Secure Enclave (AAL3)** — emergency-access keys never leave the SEP; every signing operation gated by Touch ID / Watch / passcode
- **Per-action MFA** — `LocalAuthentication` gates admin CLI commands (role assign/revoke, break-glass issuance); fails closed on headless hosts unless explicitly bypassed (every bypass logged)
- **Workload-identity federation** — VMs bind to a cloud IAM role (AWS/GCP/Azure); the host mints short-lived SEP-signed OIDC tokens, no long-lived credentials baked into images
- **Per-request signed operator-to-API auth** — P-256 ECDSA request signing with nonce replay protection, no shared static tokens
- **RBAC** — deny-by-default role assignments, multi-tenant isolation, and per-tenant VM quotas
- **Append-only audit log** — BSD `UF_APPEND` kernel flag blocks overwrites even from root
- **Zero third-party Swift dependencies for security-critical code** — TLS, signing, and crypto all come from Apple's own CryptoKit/Security/Network frameworks

**Production checklist** — follow [`docs/DEPLOYMENT_HARDENING.md`](docs/DEPLOYMENT_HARDENING.md) for the 13-item pre-flight, the reference LaunchDaemon plist, and verification commands. Run `spook doctor --strict` to verify every control at runtime, or `spook security-controls` to print an audit-ready inventory of every shipped control with OWASP / NIST / ASVS citations + code + test references.

See [`SECURITY.md`](SECURITY.md) for the full security model, [`docs/DATA_AT_REST.md`](docs/DATA_AT_REST.md) for the VM bundle protection plan (OWASP ASVS V6.1.1 / V6.4.1 / V14.2.6), [`docs/EC2_MAC_DEPLOYMENT.md`](docs/EC2_MAC_DEPLOYMENT.md) for the EC2 Mac operator profile, and [`docs/observability/`](docs/observability/) for Prometheus + Grafana kit.

## Audit & SIEM

Every control-plane action produces a structured `AuditRecord` (JSONL):

```bash
# Enable JSONL audit export
SPOOKTACULAR_AUDIT_FILE=/var/log/spooktacular/audit.jsonl spook serve ...

# Ship to Splunk/Elasticsearch via FluentBit
fluent-bit -i tail -p path=/var/log/spooktacular/audit.jsonl \
  -o es -p Host=elasticsearch.internal -p Index=spooktacular-audit

# Ship to CloudWatch Logs
aws logs put-log-events --log-group-name spooktacular \
  --log-stream-name "$(hostname)" \
  --log-events "$(jq -c '{timestamp: (.timestamp | fromdate * 1000 | floor), message: tojson}' /var/log/spooktacular/audit.jsonl)"
```

Each record contains: `actorIdentity`, `tenant`, `scope`, `resource`, `action`, `outcome`, `correlationID`, `timestamp`.

## Supply Chain

Every release ships with:

- **Notarized binary** — Apple notarization via `notarytool`
- **Build provenance** — [artifact attestation](https://github.com/Spooky-Labs/spooktacular/attestations) via `actions/attest-build-provenance`
- **SBOM** — SPDX format, attached to each [GitHub Release](https://github.com/Spooky-Labs/spooktacular/releases)

## Building from Source

```bash
swift build              # Debug build
swift build -c release   # Release build
swift test               # Run 750 tests
./build-app.sh release   # Build .app bundle
```

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| [CI](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml) | PR + push to main | `lint` (SwiftLint --strict, App Store metadata check, Danger PR review) gates `test-and-build` (750 tests + release build + .app bundle + README-claims validation) and `xcode-build` (Xcode scheme build + UI-test compile-check), which run in parallel |
| [Beta](https://github.com/Spooky-Labs/spooktacular/actions/workflows/beta.yml) | Push to main | Sign + package + upload to TestFlight |
| [Release](https://github.com/Spooky-Labs/spooktacular/actions/workflows/release.yml) | Tag `v*` | GitHub Release + TestFlight + Homebrew zip |
| [SBOM](https://github.com/Spooky-Labs/spooktacular/actions/workflows/sbom.yml) | PR (smoke test) | Validates SBOM generation produces valid SPDX JSON |

All workflows run on `macos-26` runners with Swift 6.2 and the macOS 26 SDK.

## Contributing

We follow [GitHub Flow](https://guides.github.com/introduction/flow/). PRs welcome.

1. Fork the repo
2. Create a feature branch
3. Write tests for new functionality
4. Ensure `swift test` passes (750 tests)
5. Open a PR using our [PR template](.github/pull_request_template.md)

## License

[MIT](LICENSE) — use it freely for any purpose.

---

<div align="center">

Made with 🌲🌲🌲 in Cascadia

© 2026 [Spooky Labs](https://github.com/Spooky-Labs)

</div>
