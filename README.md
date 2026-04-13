<div align="center">

<img src="Resources/icon.svg" width="128" height="128" alt="Spooktacular">

# Spooktacular

**Enterprise macOS virtualization for Apple Silicon.**

[![CI](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml/badge.svg)](https://github.com/Spooky-Labs/spooktacular/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6.0-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000?style=flat-square&logo=apple&logoColor=white)](https://developer.apple.com/macos/)

[Website](https://spooktacular.app) · [API Docs](https://spooktacular.app/api/documentation/spooktacularkit/) · [Roadmap](https://spooktacular.app/roadmap.html)

</div>

---

## What It Does

Double your EC2 Mac CI capacity at zero additional cost. Spooktacular runs macOS virtual machines on Apple Silicon using Apple's [Virtualization.framework](https://developer.apple.com/documentation/virtualization), supporting up to 2 VMs per host. Instant APFS copy-on-write cloning, automated Setup Assistant, SSH provisioning, and a full CLI/GUI/API surface make it production-ready for self-hosted GitHub Actions runners, remote desktops, and fleet management.

## Quick Start

```bash
brew install --cask spooktacular

spook create base --from-ipsw latest --cpu 8 --memory 16
spook clone base runner-01
spook clone base runner-02
spook start runner-01 --headless --user-data ./setup.sh --provision ssh
spook start runner-02 --headless --user-data ./setup.sh --provision ssh
# Two runners. One Mac. Half the cost.
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                     Consumers                           │
│  ┌────────────┐  ┌─────────┐  ┌──────────┐  ┌───────┐  │
│  │  spook CLI │  │ SwiftUI │  │ HTTP API │  │  K8s  │  │
│  │ 17 commands│  │   GUI   │  │ :8484    │  │  CRD  │  │
│  └─────┬──────┘  └────┬────┘  └────┬─────┘  └───┬───┘  │
│        └───────┬───────┴───────────┬────────────┘       │
│                ▼                   ▼                     │
│  ┌──────────────────────────────────────────────────┐   │
│  │              SpooktacularKit                      │   │
│  │  VirtualMachine    CloneManager    IPResolver     │   │
│  │  VMBundle          RestoreImage    CapacityCheck  │   │
│  │  VMConfiguration   SetupAutomation PIDFile        │   │
│  │  SnapshotManager   SSHExecutor     HTTPAPIServer  │   │
│  │  VsockProvisioner  DiskInjector    Templates      │   │
│  └──────────────────────────────────────────────────┘   │
│                        ▼                                │
│           Apple Virtualization.framework                 │
└─────────────────────────────────────────────────────────┘
```

## Features

- **Instant cloning** -- APFS copy-on-write clones a 30 GB disk in milliseconds ([CloneManager.swift](Sources/SpooktacularKit/CloneManager.swift))
- **2-VM capacity enforcement** -- Proactive kernel-limit check before boot ([CapacityCheck.swift](Sources/SpooktacularKit/CapacityCheck.swift))
- **Setup Assistant automation** -- Keyboard sequences for macOS 15 and 26 ([SetupAutomation.swift](Sources/SpooktacularKit/SetupAutomation.swift))
- **SSH provisioning** -- user-data scripts with output streaming ([SSHExecutor.swift](Sources/SpooktacularKit/SSHExecutor.swift))
- **VirtIO socket provisioning** -- Agent-based script delivery, no network needed ([VsockProvisioner.swift](Sources/SpooktacularKit/VsockProvisioner.swift))
- **IP resolution** -- DHCP leases + ARP table lookup ([IPResolver.swift](Sources/SpooktacularKit/IPResolver.swift))
- **Snapshots** -- Save and restore disk-level VM state ([SnapshotManager.swift](Sources/SpooktacularKit/SnapshotManager.swift))
- **Networking** -- NAT, bridged, or isolated modes ([NetworkMode.swift](Sources/SpooktacularKit/NetworkMode.swift))
- **Shared folders** -- VirtIO file-system device with automount ([SharedFolderProvisioner.swift](Sources/SpooktacularKit/SharedFolderProvisioner.swift))
- **LaunchDaemon service** -- Headless server with `spook service install` ([ServicePlist.swift](Sources/SpooktacularKit/ServicePlist.swift))
- **Templates** -- `--github-runner`, `--remote-desktop`, `--openclaw` script generators
- **SwiftUI GUI** -- NavigationSplitView, inspector panel, Liquid Glass (macOS 26+), menu bar extra
- **Accessibility** -- Full VoiceOver support, WCAG 2.1, reduced motion

## CLI Reference

| Command | Description |
|---------|-------------|
| `spook create <name>` | Create a VM from an IPSW restore image |
| `spook start <name>` | Boot a VM (`--headless`, `--recovery`, `--user-data`, `--provision ssh`) |
| `spook stop <name>` | Graceful shutdown via SIGTERM (`--force` for SIGKILL) |
| `spook list` | List all VMs with running state (`--json`) |
| `spook clone <src> <dst>` | Instant APFS clone with new machine identifier |
| `spook delete <name>` | Delete a VM bundle (`--force` skips confirmation) |
| `spook ip <name>` | Resolve VM IP address via DHCP/ARP |
| `spook ssh <name>` | Open an SSH session to a running VM |
| `spook exec <name> --` | Run a command on a VM via SSH |
| `spook get <name>` | Show VM configuration (`--json`, `--field cpu`) |
| `spook set <name>` | Modify VM config (`--cpu`, `--memory`, `--network`) |
| `spook snapshot <name>` | Save a disk-level snapshot |
| `spook restore <name>` | Restore a VM from a snapshot |
| `spook snapshots <name>` | List available snapshots |
| `spook share <name>` | Manage shared folders |
| `spook service` | Install/uninstall LaunchDaemon for headless operation |
| `spook serve` | Start the HTTP API server |

## HTTP API

The `spook serve` command starts a JSON API on `http://127.0.0.1:8484`.

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `GET` | `/v1/vms` | List all VMs |
| `GET` | `/v1/vms/:name` | Get VM details |
| `POST` | `/v1/vms/:name/clone` | Clone a VM (`{"source": "base"}`) |
| `POST` | `/v1/vms/:name/start` | Start a VM |
| `POST` | `/v1/vms/:name/stop` | Stop a VM |
| `DELETE` | `/v1/vms/:name` | Delete a VM |
| `GET` | `/v1/vms/:name/ip` | Resolve VM IP address |

All responses use a JSON envelope: `{"status": "ok", "data": {...}}` or `{"status": "error", "message": "..."}`.

## Kubernetes

A Kubernetes operator with a `MacOSVM` custom resource definition is planned. Manifests and Helm charts are in [`deploy/kubernetes/`](deploy/kubernetes/). See the [Kubernetes README](deploy/kubernetes/README.md) for details.

## Building from Source

```bash
git clone https://github.com/Spooky-Labs/spooktacular
cd spooktacular
swift build
swift test
./build-app.sh    # .app bundle with icon
```

Requires macOS 14+ and Swift 6.0+.

## CI/CD

Four GitHub Actions workflows automate the full lifecycle:

| Workflow | Trigger | What it does |
|----------|---------|-------------|
| [`ci.yml`](.github/workflows/ci.yml) | Every push and PR | Runs `swift test --parallel`, verifies test count |
| [`beta.yml`](.github/workflows/beta.yml) | Push to `main` | Builds and uploads to TestFlight |
| [`release.yml`](.github/workflows/release.yml) | Tag `v*` | Notarizes and submits to App Store via Fastlane |
| [`docs.yml`](.github/workflows/docs.yml) | Push to `main` | Generates DocC and deploys to GitHub Pages |

## Contributing

We use GitHub Flow. Fork, branch, PR.

1. Open an issue before major changes
2. All new code needs tests (`swift test` must pass)
3. Run `swift build` to verify compilation
4. Keep commits focused and messages descriptive

## License

[MIT](LICENSE)

<div align="center">
<br>
Made with 🌲🌲🌲 in Cascadia
<br>
<sub><a href="https://github.com/Spooky-Labs">Spooky Labs</a> · Apple, macOS, and Xcode are trademarks of Apple Inc.</sub>
</div>
