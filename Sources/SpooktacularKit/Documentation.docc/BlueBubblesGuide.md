# Running BlueBubbles iMessage Server

Set up a BlueBubbles iMessage server in a macOS VM — a dramatically simpler alternative to VMware on Windows.

## Overview

[BlueBubbles](https://bluebubbles.app) is an open-source app that brings
iMessage to Android, Windows, and Linux. It requires a macOS server running
24/7 to relay messages. Traditionally, users set this up on a dedicated Mac
or through a complex VMware-on-Windows process involving OpenCore, QEMU
image conversion, Auto-Unlocker patches, and manual VMX editing
([BlueBubbles VMware guide](https://docs.bluebubbles.app/server/advanced/macos-virtualization/running-a-macos-vm)).

**Spooktacular eliminates all of that.** On an Apple Silicon Mac, you run
one command and get an isolated macOS VM ready for BlueBubbles — using
Apple's official Virtualization framework, no Hackintosh tools required.

### Why a VM instead of bare metal?

- **Isolation** — BlueBubbles needs Full Disk Access to read iMessage's
  chat database. Running it in a VM keeps it sandboxed from your daily Mac.
- **Snapshots** — save a working iMessage configuration before macOS
  updates, roll back if something breaks.
- **Dedicated environment** — the VM can run 24/7 headless while you
  use your Mac normally.
- **Two servers** — run two BlueBubbles instances (e.g., personal +
  family Apple IDs) on one Mac using Spooktacular's 2-VM support.

## Quick Start

### 1. Create a VM

```bash
spook create bluebubbles --from-ipsw latest \
    --cpu 4 --memory 4 --disk 32 \
    --network nat \
    --user-data ./setup-bluebubbles.sh \
    --provision disk-inject
```

BlueBubbles is lightweight — 4 CPU cores and 4 GB RAM is plenty.

### 2. The setup script

Create `setup-bluebubbles.sh`:

```bash
#!/bin/bash
# setup-bluebubbles.sh — installs BlueBubbles server in a macOS VM

set -euo pipefail

# Install Homebrew
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"

# Install BlueBubbles server
brew install --cask bluebubbles-server

# Enable Screen Sharing for remote management
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -restart -agent -privs -all

echo "BlueBubbles server installed."
echo "Connect via VNC to complete Apple ID sign-in and BlueBubbles setup."
```

### 3. Start and configure

```bash
spook start bluebubbles
```

The VM opens with a display window. Complete these one-time steps:

1. **Sign in to your Apple ID** — required for iMessage
2. **Open Messages.app** — verify iMessage activates
3. **Launch BlueBubbles Server** — configure your connection
   (Firebase, Cloudflare tunnel, or Tailscale)
4. **Grant Full Disk Access** — System Settings → Privacy &
   Security → Full Disk Access → add BlueBubbles

### 4. Run headless 24/7

Once configured, restart headless:

```bash
spook stop bluebubbles
spook start bluebubbles --headless
```

The BlueBubbles server runs in the background. Access it
remotely via VNC if you need to make changes:

```bash
spook ip bluebubbles
# Connect via Screen Sharing to the reported IP
```

## Two BlueBubbles Instances

Run two iMessage servers on one Mac — one for each Apple ID:

```bash
spook create bb-personal --from-ipsw latest --cpu 4 --memory 4
spook create bb-family --from-ipsw latest --cpu 4 --memory 4

# Or clone from a configured base:
spook create bb-personal --from-ipsw latest --user-data ./setup-bluebubbles.sh
# Configure Apple ID #1...
spook stop bb-personal

spook clone bb-personal bb-family
# Start bb-family and sign in with Apple ID #2
spook start bb-family
# Configure Apple ID #2...

# Run both headless
spook start bb-personal --headless
spook start bb-family --headless
```

> Important: Each VM gets a unique ``VZMacMachineIdentifier``.
> iMessage activation is per-machine-identifier. Cloning creates
> a new identity, so you must re-activate iMessage on the clone.

## Comparison: Spooktacular vs VMware-on-Windows

The [BlueBubbles VMware guide](https://docs.bluebubbles.app/server/advanced/macos-virtualization/running-a-macos-vm/deploying-macos-in-vmware-on-windows-full-guide)
requires 20+ steps including BIOS configuration, Python/QEMU
installation, OpenCore recovery download, DMG-to-VMDK conversion,
Auto-Unlocker patching, VMX file editing, and Clover Configurator
for iServices. It runs macOS on non-Apple hardware (unsupported
by Apple, may violate the EULA).

| | VMware on Windows | Spooktacular |
|---|---|---|
| Steps to working VM | 20+ manual steps | 1 command |
| macOS installation | OpenCore + Recovery | Apple's official IPSW |
| Hardware | Any x86 PC | Apple Silicon Mac |
| Apple EULA | Violates (non-Apple HW) | Compliant |
| iMessage activation | Requires fake serial numbers | Works natively |
| Performance | Emulated, slow | Near-native (VirtIO) |
| GPU acceleration | None | Metal via VZ framework |
| Maintenance | Manual patching per update | `spook create --from-ipsw latest` |
| Snapshots | VMware snapshots | `spook snapshot` (APFS) |
| 24/7 headless | Complex configuration | `spook start --headless` |

## iCloud and iMessage in VMs

As of macOS 15 (Sequoia), Apple officially supports iCloud sign-in
inside macOS VMs created with the Virtualization framework. This
means iMessage activation works natively — no fake serial numbers
or Clover Configurator needed.

> Note: iCloud support requires macOS 15+ on both the host and
> the guest. Earlier macOS versions may have issues with iMessage
> activation in VMs. See Apple's documentation:
> [Using iCloud with macOS virtual machines](https://developer.apple.com/documentation/virtualization/using-icloud-with-macos-virtual-machines).

## Networking for BlueBubbles

BlueBubbles needs outbound internet access to reach Firebase/Cloudflare.
NAT networking (the default) provides this without any additional
configuration:

```bash
spook create bluebubbles --network nat   # default, works out of the box
```

For advanced setups where other devices on your LAN need to reach
the BlueBubbles server directly:

```bash
spook create bluebubbles --network bridged:en0  # own IP on LAN
```

## Monitoring

```bash
# Check VM status
spook list

# Get the VM's IP (for VNC access)
spook ip bluebubbles

# View configuration
spook get bluebubbles
```

## Topics

### Related

- <doc:GettingStarted>
- <doc:RemoteDesktop>
- ``ProvisioningMode``
- ``NetworkMode``
