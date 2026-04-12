# CLI Reference

Complete reference for the `spook` command-line interface.

## Overview

The `spook` CLI manages macOS virtual machines on Apple Silicon.
It provides commands for creating, starting, stopping, cloning,
and configuring VMs, backed by the same ``SpooktacularKit`` library
used by the GUI app and Kubernetes operator.

### Installation

#### Homebrew (Recommended)

```bash
brew install --cask spooktacular

# Verify
spook --version
# spook 0.1.0
```

#### From the .app Bundle

If you installed Spooktacular.app, the CLI is bundled inside:

```bash
# Symlink to /usr/local/bin
sudo ln -sf /Applications/Spooktacular.app/Contents/MacOS/spook /usr/local/bin/spook
```

## Commands

### spook create

Creates a new macOS virtual machine from an IPSW restore image or
OCI container image.

```
USAGE: spook create <name> [options]
```

**Arguments:**

| Argument | Description |
|----------|-------------|
| `<name>` | Name for the new VM |

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--from-ipsw <source>` | `latest` | IPSW source: `latest` or path to local `.ipsw` |
| `--cpu <n>` | 4 | CPU cores (minimum 4, see ``VMSpec/minimumCPUCount``) |
| `--memory <n>` | 8 | Memory in GB |
| `--disk <n>` | 64 | Disk size in GB (APFS sparse) |
| `--displays <n>` | 1 | Virtual displays (1 or 2) |
| `--network <mode>` | nat | Network mode: `nat`, `isolated`, `host-only`, `bridged:<iface>` |
| `--bridged-interface <iface>` | - | Host interface for bridged mode |
| `--user-data <path>` | - | Shell script to run after first boot |
| `--provision <mode>` | disk-inject | Provisioning mode (see ``ProvisioningMode``) |
| `--ssh-user <user>` | admin | SSH user for `--provision ssh` |
| `--ssh-key <path>` | ~/.ssh/id_ed25519 | SSH private key for `--provision ssh` |
| `--share <path>` | - | Host directory to share (repeatable) |
| `--enable-audio` / `--disable-audio` | enabled | Audio output |
| `--enable-microphone` / `--disable-microphone` | disabled | Microphone passthrough |
| `--enable-auto-resize` / `--disable-auto-resize` | enabled | Auto-resize display |
| `--github-runner` | false | Configure as a GitHub Actions runner |
| `--github-repo <org/repo>` | - | GitHub repository for `--github-runner` |
| `--github-token <token>` | - | Runner registration token for `--github-runner` |
| `--openclaw` | false | Configure as an OpenClaw AI agent |
| `--remote-desktop` | false | Enable Screen Sharing (VNC) |
| `--ephemeral` | false | Destroy and recreate after each job |

**Examples:**

```bash
# Create from latest IPSW
spook create my-vm

# Custom hardware
spook create runner --cpu 8 --memory 16 --disk 100

# With provisioning script
spook create ci --from-ipsw latest \
    --user-data ~/setup.sh \
    --provision disk-inject

# From a local IPSW file
spook create dev --from-ipsw ~/Downloads/macOS15.4.ipsw

# As a GitHub Actions runner
spook create runner --from-ipsw latest \
    --github-runner --github-repo myorg/myrepo --github-token ghp_xxx

# With shared folder
spook create ml --cpu 8 --memory 16 \
    --share /data/training \
    --network host-only

> Note: OCI image pull is on the roadmap. For now, use `--from-ipsw` to create VMs.
```

**Exit codes:** 0 on success, 1 if the VM already exists or
creation fails.

---

### spook start

Starts a stopped virtual machine.

```
USAGE: spook start <name> [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--headless` | false | Run without a display window |
| `--recovery` | false | Boot into macOS Recovery mode |
| `--user-data <path>` | - | Script to run after boot |
| `--provision <mode>` | ssh | Provisioning mode for `--user-data` |

**Examples:**

```bash
# Start with display window
spook start my-vm

# Start headless (CI runners, servers)
spook start runner-01 --headless

# Boot into Recovery mode
spook start my-vm --recovery

# Start with a provisioning script
spook start my-vm --user-data ~/fix.sh --provision ssh
```

**Exit codes:** 0 on success, 1 if the VM is not found.

---

### spook stop

Stops a running virtual machine.

```
USAGE: spook stop <name>
```

**Examples:**

```bash
spook stop my-vm
spook stop my-vm --force
```

> Note: `spook stop` reads the PID file from the VM bundle and
> sends SIGTERM to the `spook start` process that owns the VM.
> That process handles SIGTERM by gracefully stopping the VM,
> cleaning up the PID file, and exiting. Use `--force` to send
> SIGKILL if the process is unresponsive.

**Exit codes:** 0 on success, 1 if the VM is not found.

---

### spook list

Lists all virtual machines with their status and configuration.

```
USAGE: spook list [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--json` | false | Output as JSON |

**Examples:**

```bash
# Human-readable table
spook list

# NAME        CPU     MEM     DISK    NET    STATUS
# runner-01   4 cores 8 GB    64 GB   nat    ready
# runner-02   4 cores 8 GB    64 GB   nat    ready
# dev         8 cores 16 GB   100 GB  nat    pending

# Machine-readable JSON
spook list --json
```

**JSON output fields:** `name`, `cpu`, `memoryGB`, `diskGB`,
`displays`, `network`, `audio`, `setupCompleted`, `id`, `path`.

**Exit codes:** 0 always.

---

### spook get

Shows the full configuration of a virtual machine.

```
USAGE: spook get <name> [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--json` | false | Output as JSON |
| `--field <name>` | - | Print only one field value |

**Available fields:** `cpu`, `memory`, `disk`, `displays`, `network`,
`audio`, `microphone`, `id`, `setup`.

**Examples:**

```bash
# Full styled output
spook get runner-01

# JSON output
spook get runner-01 --json

# Extract a single field (for scripting)
spook get runner-01 --field cpu
# 4

spook get runner-01 --field id
# 550e8400-e29b-41d4-a716-446655440000
```

**Exit codes:** 0 on success, 1 if the VM or field is not found.

---

### spook clone

Creates an instant copy-on-write clone of a virtual machine.

```
USAGE: spook clone <source> <destination>
```

**Arguments:**

| Argument | Description |
|----------|-------------|
| `<source>` | Name of the VM to clone |
| `<destination>` | Name for the new clone |

**Examples:**

```bash
# Clone a base VM for CI runners
spook clone base runner-01
spook clone base runner-02

# Clone for testing
spook clone dev-env test-env
```

Cloning uses APFS `clonefile(2)` for the disk image, making it
nearly instantaneous regardless of disk size. Each clone receives
a fresh `VZMacMachineIdentifier` (see ``CloneManager``).

**Exit codes:** 0 on success, 1 if source not found or destination
exists.

---

### spook delete

Permanently deletes a virtual machine and all its data.

```
USAGE: spook delete <name> [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--force` | false | Skip confirmation prompt |

**Examples:**

```bash
# Interactive confirmation
spook delete old-vm

# Skip confirmation (for scripts)
spook delete runner-01 --force
```

> Important: This removes the entire VM bundle including the disk
> image, configuration, and all snapshots. This operation cannot
> be undone.

**Exit codes:** 0 on success, 1 if the VM is not found.

---

### spook set

Modifies the configuration of a stopped virtual machine.

```
USAGE: spook set <name> [options]
```

Only the options you specify are changed. All others remain at
their current values.

**Options:**

| Option | Description |
|--------|-------------|
| `--cpu <n>` | CPU cores (minimum 4) |
| `--memory <n>` | Memory in GB |
| `--displays <n>` | Virtual displays (1 or 2) |
| `--network <mode>` | Network mode |
| `--enable-audio` / `--disable-audio` | Audio output |
| `--enable-microphone` / `--disable-microphone` | Microphone |
| `--enable-auto-resize` / `--disable-auto-resize` | Display auto-resize |

**Examples:**

```bash
# Increase CPU and memory
spook set my-vm --cpu 8 --memory 16

# Switch to bridged networking
spook set my-vm --network bridged:en0

# Add a second display
spook set my-vm --displays 2

# Disable audio for headless CI
spook set runner --disable-audio
```

**Exit codes:** 0 on success, 1 if the VM is not found.

---

### spook ip

Shows the IP address of a running virtual machine.

```
USAGE: spook ip <name>
```

**Examples:**

```bash
spook ip runner-01
# 192.168.64.3

# Use in scripts
ssh admin@$(spook ip my-vm)
```

**Exit codes:** 0 on success, 1 if the VM is not found or not
running.

---

### spook ssh

Opens an interactive SSH connection to a running VM.

```
USAGE: spook ssh <name> [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--user <name>` | admin | SSH user name |
| `--key <path>` | ~/.ssh/id_ed25519 | Path to SSH private key |

**Examples:**

```bash
# Default connection
spook ssh my-vm

# Custom user and key
spook ssh runner-01 --user ci --key ~/.ssh/ci_ed25519
```

> Note: The VM must have Remote Login (SSH) enabled in System
> Settings > General > Sharing > Remote Login.

**Exit codes:** 0 on success, 1 if the VM is not found.

---

### spook exec

Executes a command inside a running virtual machine.

```
USAGE: spook exec <name> [options] -- <command...>
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--user <name>` | admin | SSH user name |

**Examples:**

```bash
# Run a single command
spook exec my-vm -- uname -a

# Check macOS version
spook exec my-vm -- sw_vers

# Run a shell command
spook exec my-vm -- /bin/bash -c "echo hello && whoami"

# Install a package
spook exec runner-01 --user ci -- brew install git
```

> Important: Use `--` to separate `spook` options from the guest
> command.

**Exit codes:** 0 on success, non-zero if the command fails in the
guest.

---

### spook snapshot

Saves a disk-level snapshot of a VM. Copies `disk.img` and
`auxiliary.bin` into a `SavedStates/<label>/` directory inside
the VM bundle, along with a `snapshot-info.json` metadata file.

The VM must be **stopped** before snapshotting. Disk-level
snapshots work across processes and reboots -- no running VM
process is required, unlike VZ state save.

```
USAGE: spook snapshot <name> <label>
```

**Arguments:**

| Argument | Description |
|----------|-------------|
| `<name>` | Name of the VM |
| `<label>` | Label for the snapshot |

**Examples:**

```bash
spook snapshot my-vm clean-install
spook snapshot runner before-xcode
```

See ``SnapshotManager`` for the API details.

---

### spook restore

Restores a VM's disk state from a previously saved snapshot.
Replaces the current `disk.img` and `auxiliary.bin` with the
copies stored in the snapshot directory.

The VM must be **stopped** before restoring.

```
USAGE: spook restore <name> <label>
```

**Examples:**

```bash
spook restore my-vm clean-install
spook restore runner before-xcode
```

---

### spook snapshots

Lists all snapshots for a virtual machine, showing each
snapshot's label, creation date, and size.

```
USAGE: spook snapshots <name>
```

**Examples:**

```bash
spook snapshots my-vm
# LABEL            DATE                  SIZE
# ──────────────   ──────────────────    ──────
# clean-install    Jan 15, 2025 10:30    2.1 GB
# before-xcode     Jan 16, 2025 14:22    3.8 GB
```

---

### spook share

Manages shared folders for a virtual machine. Shared folder
configuration is persisted in the VM's `config.json` and applied
at start time via `VZVirtioFileSystemDeviceConfiguration`.

This is a subcommand group with three operations.

#### spook share add

Adds a host directory as a shared folder in the VM.

```
USAGE: spook share <vm-name> add <path> [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--tag <name>` | directory name | Mount tag for guest identification |
| `--read-only` | false | Mount as read-only in the guest |

**Examples:**

```bash
spook share my-vm add ~/Projects --tag projects
spook share my-vm add /data --tag data --read-only
```

See ``SharedFolder`` for how tags and mount points work.

#### spook share remove

Removes a shared folder by its tag.

```
USAGE: spook share <vm-name> remove <tag>
```

**Examples:**

```bash
spook share my-vm remove projects
```

#### spook share list

Lists all shared folders for a VM.

```
USAGE: spook share <vm-name> list
```

**Examples:**

```bash
spook share my-vm list
# TAG        PATH                    PERMS
# projects   /Users/me/Projects      rw
# data       /data/training          ro
```

---

### spook service

Manages the Spooktacular LaunchDaemon for headless server
operation. This is a subcommand group with three operations.

> Note: `spook service install` creates a LaunchDaemon for
> headless servers. It writes a plist to
> `/Library/LaunchDaemons/com.spooktacular.daemon.plist` and
> loads it via `launchctl`. The daemon starts automatically at
> boot and runs the Spooktacular API server.

#### spook service install

Installs the LaunchDaemon. Requires `sudo`.

```
USAGE: sudo spook service install [options]
```

**Options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--bind <addr:port>` | `0.0.0.0:9470` | API listen address |

**Examples:**

```bash
sudo spook service install
sudo spook service install --bind 127.0.0.1:9470
```

#### spook service uninstall

Unloads and removes the LaunchDaemon. Requires `sudo`.

```
USAGE: sudo spook service uninstall
```

#### spook service status

Reports whether the LaunchDaemon is installed and running.

```
USAGE: spook service status
```

**Examples:**

```bash
spook service status
# Spooktacular LaunchDaemon
#   Plist    installed
#   Path     /Library/LaunchDaemons/com.spooktacular.daemon.plist
#   Status   running
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NO_COLOR` | - | When set (to any value), disables colored output |
| `SPOOK_API_TOKEN` | - | Bearer token for the control API |
| `SPOOK_API_URL` | `http://127.0.0.1:9470` | Control API base URL |
| `SPOOK_HOME` | `~/.spooktacular` | Data directory path |

```bash
# Disable colors (respects the NO_COLOR standard)
NO_COLOR=1 spook list

# Use a remote Spooktacular host
SPOOK_API_URL=http://10.0.1.50:9470 \
SPOOK_API_TOKEN=my-secret-token \
spook list
```

## JSON Output for Automation

Most commands support `--json` for machine-readable output:

```bash
# List VMs as JSON
spook list --json

# Get VM config as JSON
spook get runner-01 --json

# Parse with jq
spook list --json | jq '.[] | select(.setupCompleted == true) | .name'
```

### JSON Output Structure

`spook list --json` returns an array of objects:

```json
[
  {
    "name": "runner-01",
    "cpu": 4,
    "memoryGB": 8,
    "diskGB": 64,
    "displays": 1,
    "network": "nat",
    "audio": true,
    "setupCompleted": true,
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "path": "/Users/me/.spooktacular/vms/runner-01.vm"
  }
]
```

## Field Extraction for Scripting

Use `--field` with `spook get` to extract a single value without
parsing JSON:

```bash
# Get CPU count
spook get runner-01 --field cpu
# 4

# Get VM ID
spook get runner-01 --field id
# 550e8400-e29b-41d4-a716-446655440000

# Use in a script
CPU=$(spook get runner-01 --field cpu)
if [ "$CPU" -lt 8 ]; then
    spook set runner-01 --cpu 8
fi
```

**Available fields:** `cpu`, `memory`, `disk`, `displays`, `network`,
`audio`, `microphone`, `id`, `setup`.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (VM not found, invalid arguments, operation failed) |
| 2 | Usage error (invalid command syntax) |
| 130 | Interrupted (Ctrl+C) |

```bash
# Check exit code in scripts
spook get my-vm --field cpu > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "VM not found"
fi
```

## Shell Completion

Install tab completion for your shell:

### Bash

```bash
spook --generate-completion-script bash > /etc/bash_completion.d/spook
source /etc/bash_completion.d/spook
```

### Zsh

```bash
spook --generate-completion-script zsh > /usr/local/share/zsh/site-functions/_spook
autoload -Uz compinit && compinit
```

### Fish

```bash
spook --generate-completion-script fish > ~/.config/fish/completions/spook.fish
```

After installation, pressing Tab will complete command names,
VM names, and option flags.

## Using spook in CI Scripts

### GitHub Actions

```yaml
jobs:
  test:
    runs-on: [self-hosted, macos]
    steps:
      - name: Create test VM
        run: |
          spook create test-vm --cpu 4 --memory 8 --disk 64 \
              --user-data scripts/setup.sh \
              --provision disk-inject
          spook start test-vm --headless

      - name: Run tests
        run: |
          spook exec test-vm -- /bin/bash -c "
              cd /Users/admin/project
              xcodebuild test -scheme MyApp -sdk iphonesimulator
          "

      - name: Cleanup
        if: always()
        run: spook delete test-vm --force
```

### Shell Scripts

```bash
#!/bin/bash
set -euo pipefail

# Create and configure
spook create build-vm --cpu 8 --memory 16 --disk 100
spook start build-vm --headless

# Wait for boot (check IP availability)
while ! spook ip build-vm > /dev/null 2>&1; do
    sleep 5
done

# Execute build
spook exec build-vm -- /bin/bash -c "
    cd /Users/admin
    git clone https://github.com/myorg/myrepo.git
    cd myrepo
    xcodebuild archive -scheme MyApp
"

# Extract artifacts via shared folder or SCP
IP=$(spook ip build-vm)
scp admin@$IP:/Users/admin/myrepo/build/MyApp.xcarchive.zip ./

# Cleanup
spook delete build-vm --force
```

## Integration with Other Tools

### jq (JSON Processing)

```bash
# Find all VMs with more than 4 CPU cores
spook list --json | jq '.[] | select(.cpu > 4) | .name'

# Calculate total memory across all VMs
spook list --json | jq '[.[].memoryGB] | add'

# Get VMs that are ready
spook list --json | jq '[.[] | select(.setupCompleted)] | length'
```

### kubectl (Kubernetes)

```bash
# Get Spooktacular-managed K8s VMs and local VMs side by side
echo "=== Kubernetes VMs ==="
kubectl get macosvm -A
echo ""
echo "=== Local VMs ==="
spook list
```

### gh (GitHub CLI)

```bash
# Check runner registration status
RUNNERS=$(gh api repos/myorg/myrepo/actions/runners --jq '.runners[] | .name')

# Cross-reference with local VMs
spook list --json | jq -r '.[].name' | while read vm; do
    if echo "$RUNNERS" | grep -q "$vm"; then
        echo "$vm: registered"
    else
        echo "$vm: NOT registered"
    fi
done
```

## Data Directory Layout

All Spooktacular data lives under `~/.spooktacular/`:

```
~/.spooktacular/
├── vms/                     VM bundles
│   ├── runner-01.vm/
│   │   ├── config.json      VMSpec (CPU, memory, etc.)
│   │   ├── metadata.json    VMMetadata (ID, dates)
│   │   ├── disk.img         APFS sparse disk image
│   │   ├── auxiliary.bin    VZ auxiliary storage
│   │   ├── hardware-model.bin
│   │   ├── machine-identifier.bin
│   │   └── SavedStates/     Snapshots
│   │       └── clean-install/
│   └── runner-02.vm/
├── cache/
│   └── ipsw/                Cached IPSW downloads
│       └── <sha256>.ipsw
├── images/
│   └── library.json         Image library index
├── config.yaml              Global configuration
└── api-token                API bearer token
```

See ``VMBundle`` for the bundle directory structure and ``ImageLibrary``
for the image cache.

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:Provisioning>
- <doc:EC2MacDeployment>
- <doc:GitHubActionsGuide>

### Key Types

- ``VMBundle``
- ``VMSpec``
- ``VMMetadata``
- ``CloneManager``
- ``ProvisioningMode``
- ``NetworkMode``
- ``ImageLibrary``
