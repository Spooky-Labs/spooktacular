<div align="center">
  <img src="Resources/AppIcon.svg" width="128" height="128" alt="Spooktacular — Two ghosts dancing by a campfire">

  # Spooktacular

  **Double your Mac capacity. Same hardware.**

  macOS Virtualization for Teams on Apple Silicon. Run 2 VMs per Mac —<br>
  the maximum Apple's EULA allows. Clone in 48ms. MIT licensed, $0 forever.

  [![CI](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml/badge.svg)](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml)
  [![License: MIT](https://img.shields.io/badge/License-MIT-a78bfa.svg)](LICENSE)
  [![Swift 6](https://img.shields.io/badge/Swift-6.2-a78bfa.svg)](https://swift.org)
  [![macOS 14+](https://img.shields.io/badge/macOS-14+-a78bfa.svg)](https://developer.apple.com/macos/)
  [![Tests](https://img.shields.io/badge/Tests-424_passing-22c55e.svg)](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml)

  [Website](https://spooktacular.app) · [Download](https://github.com/Spooky-Labs/spooktacular/releases/latest/download/Spooktacular.app.zip) · [API Docs](https://spooktacular.app/api/documentation/spooktacularkit/) · [Get Started](#-summon-your-first-vm)

</div>

---

## Why Spooktacular

- **2 VMs per Mac** — The maximum Apple's [EULA (Section 2B(iii))](https://www.apple.com/legal/sla/) allows, enforced at the kernel level. Every Mac mini, Mac Studio, or Mac Pro becomes two workloads.
- **48ms clones** — APFS copy-on-write duplicates a 64GB VM in milliseconds. No disk copy, no waiting.
- **Everything that needs a Mac** — CI/CD runners, iOS/macOS code signing, remote desktops, MDM profile signing, computer-using AI agents (iMessage, Final Cut Pro, Xcode).
- **$0 forever** — MIT licensed. No sales calls. No per-core fees. Audit every line of [source code](https://github.com/Spooky-Labs/spooktacular).

## Screenshots

<div align="center">
<table>
<tr>
<td align="center"><strong>SwiftUI App (Liquid Glass)</strong></td>
<td align="center"><strong>CLI — 14 commands</strong></td>
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
# Install (or download from https://spooktacular.app/download.html)
brew install --cask spooktacular

# Create a base VM from the latest macOS
spook create base --from-ipsw latest

# Clone it — 48ms, APFS copy-on-write
spook clone base runner-01

# Start as a GitHub Actions runner
spook start runner-01 --headless --github-runner \
  --github-repo your-org/repo --github-token ghp_xxx

# Double your capacity — ephemeral runners auto-destroy after each job
spook clone base runner-02
spook start runner-02 --ephemeral --headless --github-runner \
  --github-repo your-org/repo --github-token ghp_xxx
```

## Architecture

```
┌─────────────────────────────────────────┐
│              SpookCore                  │
│  Domain types · Protocols · Policies    │
│  TenancyModel · RunnerStateMachine      │
│  AuthorizationContext · ReusePolicy     │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│           SpookApplication              │
│  Use cases · Ports · Orchestration      │
│  RunnerPoolManager · GitHubRunner       │
│  WebhookVerifier · Metrics · Tenancy    │
└─────────────────┬───────────────────────┘
                  │
┌─────────────────▼───────────────────────┐
│       SpookInfrastructureApple          │
│  VZ* · Network · Security · CryptoKit  │
│  HTTPAPIServer · GuestAgentClient       │
│  Keychain · TLS · ProcessRunner         │
└─────┬──────────┬──────────┬─────────────┘
      │          │          │
 ┌────▼──┐  ┌───▼───┐  ┌──▼────────┐
 │ spook │  │  GUI  │  │ controller │
 │ (CLI) │  │(SwiftUI│  │   (K8s)   │
 └───────┘  └───────┘  └────────────┘
```

Clean Architecture with compiler-enforced boundaries. SpookCore imports Foundation only.
SpookApplication depends on SpookCore only. Infrastructure wraps Apple frameworks.

## Features

| Feature | Source | Description |
|---|---|---|
| VM Creation | [`RestoreImageManager.swift`](Sources/SpookInfrastructureApple/RestoreImageManager.swift) | Auto-download latest compatible macOS IPSW, install |
| APFS Cloning | [`CloneManager.swift`](Sources/SpookInfrastructureApple/CloneManager.swift) | Copy-on-write clone with new MachineIdentifier |
| VM Lifecycle | [`VirtualMachine.swift`](Sources/SpookInfrastructureApple/VirtualMachine.swift) | Start, stop, pause, resume, save/restore state |
| Setup Assistant | [`SetupAutomationExecutor.swift`](Sources/SpookInfrastructureApple/SetupAutomationExecutor.swift) | Unattended keyboard automation (macOS 15 + 26) |
| SSH Provisioning | [`SSHExecutor.swift`](Sources/SpookInfrastructureApple/SSHExecutor.swift) | Wait for SSH, execute scripts with streaming output |
| Disk-Inject | [`DiskInjector.swift`](Sources/SpookInfrastructureApple/DiskInjector.swift) | Mount guest disk, inject LaunchDaemon — zero network |
| Guest Agent | [`spooktacular-agent/`](Sources/spooktacular-agent/) | 12 HTTP endpoints: clipboard, exec, apps, files, ports, health |
| Agent Client | [`GuestAgentClient.swift`](Sources/SpookInfrastructureApple/GuestAgentClient.swift) | Host-side actor for all guest agent operations |
| Templates | [`GitHubRunnerTemplate.swift`](Sources/SpookApplication/GitHubRunnerTemplate.swift) | GitHub Actions, remote desktop, OpenClaw — auto-execute |
| Ephemeral Runners | [`Start.swift`](Sources/spook/Commands/Start.swift) | `--ephemeral` auto-destroys VM on stop |
| Snapshots | [`SnapshotManager.swift`](Sources/SpookInfrastructureApple/SnapshotManager.swift) | Save, restore, list, delete disk-level snapshots |
| Capacity Check | [`CapacityCheck.swift`](Sources/SpookInfrastructureApple/CapacityCheck.swift) | Enforces 2-VM kernel limit with actionable errors |
| HTTP API | [`HTTPAPIServer.swift`](Sources/SpookInfrastructureApple/HTTPAPIServer.swift) | 9 REST endpoints, TLS support, bearer token auth |
| Kubernetes | [`Sources/spook-controller/`](Sources/spook-controller/) | MacOSVM CRD, Swift controller, Helm chart |
| Service | [`ServicePlist.swift`](Sources/SpookApplication/ServicePlist.swift) | Per-VM LaunchDaemon for headless servers |
| Networking | [`VirtualMachineConfiguration.swift`](Sources/SpookInfrastructureApple/VirtualMachineConfiguration.swift) | NAT, bridged, isolated |
| Accessibility | GUI sources | Full VoiceOver: labels, hints, identifiers, announcements |

## CLI Reference

| Command | Description |
|---|---|
| `spook create` | Create a VM from an IPSW restore image |
| `spook clone` | Clone a VM (APFS copy-on-write, ~48ms) |
| `spook start` | Start a VM (headless or windowed) |
| `spook stop` | Stop a running VM |
| `spook delete` | Delete a VM bundle |
| `spook list` | List all VMs with status |
| `spook get` | Read VM configuration fields |
| `spook set` | Modify VM configuration |
| `spook ip` | Resolve a running VM's IP address |
| `spook ssh` | SSH into a running VM |
| `spook exec` | Execute a command in a VM over SSH |
| `spook snapshot` | Save or restore disk-level snapshots |
| `spook service` | Install/uninstall per-VM LaunchDaemons |
| `spook share` | Manage VirtIO shared folders |
| `spook serve` | Start the HTTP API server |
| `spook remote` | Interact with the guest agent (exec, clipboard, apps, ports, health) |

## HTTP API

```bash
spook serve --port 8484 --host 127.0.0.1
```

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/health` | Health check |
| `GET` | `/v1/vms` | List all VMs |
| `GET` | `/v1/vms/:name` | Get VM details |
| `POST` | `/v1/vms/:name/clone` | Clone from a base VM |
| `POST` | `/v1/vms/:name/start` | Start a VM |
| `POST` | `/v1/vms/:name/stop` | Stop a VM |
| `DELETE` | `/v1/vms/:name` | Delete a VM |
| `GET` | `/v1/vms/:name/ip` | Resolve VM IP |

## Guest Agent

The [guest agent](Sources/spooktacular-agent/) runs inside the VM and provides 12 HTTP endpoints over VirtIO socket — no SSH needed.

```bash
# Check agent connectivity
spook remote health my-vm

# Run a command in the guest
spook remote exec my-vm -- "sw_vers"

# Clipboard sync
spook remote clipboard get my-vm
spook remote clipboard set my-vm "hello from host"

# List running apps
spook remote apps my-vm

# List listening ports
spook remote ports my-vm
```

The host-side [`GuestAgentClient`](Sources/SpookInfrastructureApple/GuestAgentClient.swift) provides a typed Swift API for all endpoints. Install the agent in the guest with `spooktacular-agent --install-agent` (LaunchAgent for clipboard/app access).

## Runner Pools (Kubernetes)

The fastest way to get CI runners on Mac:

```bash
# Install CRDs + controller
kubectl apply -f deploy/kubernetes/crds/
helm install spooktacular deploy/kubernetes/helm/spooktacular/

# Create a GitHub Actions runner pool — 2 ephemeral runners
kubectl create secret generic github-runner-token \
  --from-literal=token=ghp_xxx
kubectl apply -f deploy/kubernetes/examples/github-runner-pool.yaml

# Watch runners come online
kubectl get rp -w
# NAME              READY  BUSY  MIN  MAX  MODE       PHASE    AGE
# ios-ci-runners    2      0     2    4    ephemeral  Healthy  30s
```

Three CI integrations: **GitHub Actions**, **CircleCI**, **Jenkins**. Three lifecycle modes: **ephemeral** (fresh clone per job), **warm-pool** (scrub and reuse), **persistent** (long-lived agents). See [`deploy/kubernetes/README.md`](deploy/kubernetes/README.md) for the full architecture.

## EC2 Mac Quickstart

Turn one EC2 Mac Dedicated Host into two schedulable macOS worker slots:

```bash
# Enterprise: install via Systems Manager
aws ssm send-command --instance-ids i-xxx --document-name "SpooktacularInstall"

# Development: download signed binary
curl -fsSL https://github.com/Spooky-Labs/spooktacular/releases/latest/download/spook -o /usr/local/bin/spook
spook doctor
```

```bash
# Validate the host
spook doctor
# ✓ Apple Silicon (arm64)
# ✓ macOS 15.4.0
# ✓ Disk space: 234 GB free
# ✓ Base VM found: base
# ✓ Capacity: 0/2 VMs running
```

Includes Terraform module, SSM automation, and bootstrap script. See [`deploy/ec2-mac/README.md`](deploy/ec2-mac/README.md).

## Security

Spooktacular is a **single-tenant, single-host** system. The security model is designed for teams that own their Mac hardware:

- **HTTP API**: TLS via `--tls-cert`/`--tls-key`, bearer token required in production
- **Guest agent**: Scoped tokens (full-access vs read-only), host CID verification, audit logging
- **Capacity**: flock-serialized PID writes prevent TOCTOU races

See [SECURITY.md](SECURITY.md) for the full threat model, known limitations, and what this tool is **not** designed for.

## Building from Source

```bash
swift build              # Debug build
swift build -c release   # Release build
swift test               # Run 424 tests
./build-app.sh release   # Build .app bundle
```

## CI/CD

| Workflow | Trigger | What it does |
|---|---|---|
| [CI](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml) | PR + push to main | 424 tests + release build + .app bundle |
| [Beta](https://github.com/Spooky-Labs/spooktacular/actions/workflows/beta.yml) | Push to main | Sign + package + upload to TestFlight |
| [Release](https://github.com/Spooky-Labs/spooktacular/actions/workflows/release.yml) | Tag `v*` | GitHub Release + TestFlight + Homebrew zip |
| [Docs](https://github.com/Spooky-Labs/spooktacular/actions/workflows/docs.yml) | Push to main | DocC generation + GitHub Pages deploy |

All workflows run on `macos-26` runners with Swift 6.2 and the macOS 26 SDK.

## Contributing

We follow [GitHub Flow](https://guides.github.com/introduction/flow/). PRs welcome.

1. Fork the repo
2. Create a feature branch
3. Write tests for new functionality
4. Ensure `swift test` passes (360+ tests)
5. Open a PR using our [PR template](.github/PULL_REQUEST_TEMPLATE.md)

## License

[MIT](LICENSE) — use it freely for any purpose.

---

<div align="center">

Made with 🌲🌲🌲 in Cascadia

© 2026 [Spooky Labs](https://github.com/Spooky-Labs)

</div>
