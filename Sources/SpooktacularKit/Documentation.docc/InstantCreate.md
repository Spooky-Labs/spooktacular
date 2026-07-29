# Instant macOS VM Creation

How Spooktacular creates macOS VMs in seconds without root, by installing
macOS once into a shared base image and giving every VM its own
copy-on-write overlay.

## Overview

Installing macOS takes 10–20 minutes and writing a provisioner into a guest
disk needs root. Doing both per VM makes every create slow and privileged.
Spooktacular does them **once**:

```
~/.spooktacular/cache/base/
└── 27A5301a/                 ← one directory per macOS build
    ├── base.asif             ← macOS installed, provisioner injected, sealed read-only, never booted
    ├── auxiliary.bin         ← cloned into each VM
    ├── hardware-model.bin
    └── base.json             ← BaseImageDescriptor
```

Each VM is then a thin layer on top:

```
~/.spooktacular/vms/<uuid>.vm/
├── disk-overlay.asif         ← this VM's writes only; the base stays untouched
├── auxiliary.bin             ← APFS clone of the base's
├── machine-identifier.bin    ← freshly minted, never shared
└── metadata.json             ← records the base, subnet and published ports
```

This is Apple's documented DiskImageKit workflow: "a shared, read-only base
image with per-VM overlay layers. Each virtual machine gets its own overlay
that captures writes while the base remains untouched."

## Why the first create asks for root

The provisioner LaunchDaemon that runs your first-boot script is written into
the **base image**, as `root:wheel`, at base-build time. That is the only
privileged step in the system, and it happens once per macOS build.

On an EC2 Mac, where Spooktacular runs as a root service, nothing is ever
asked. Locally, either run the first create under `sudo`, or approve the
privileged helper once in System Settings — after which the GUI can build
bases itself.

Every create after that is entirely unprivileged: an overlay file, two APFS
clones, and a new machine identifier.

## Why the base is never booted

A base image is installed and then sealed without starting it. Two properties
follow, and both matter:

- Its `layerUUID` never changes, so every overlay stacked on it stays valid —
  and a pool scrub can *prove* the base is pristine rather than assume it.
- Each VM's first boot is genuinely the guest's "first boot after restore",
  which is when `VZMacGuestProvisioningOptions` creates that VM's own account.
  A booted base would have consumed that moment once, for everybody.

## Published ports

macOS VMs can expose a guest service on the host, the way `docker -p` does:

```bash
spook create agent --openclaw --publish 18789:18789
open http://localhost:18789
```

Each VM gets its own private `/24` and a DHCP-reserved address, so `spook ip`
is a metadata read rather than a lease-file scrape, and publications become
vmnet forwarding rules pointing at an address known before the VM even starts.
Templates contribute defaults — OpenClaw publishes its gateway automatically —
and an explicit `--publish` on the same host port replaces the default, because
vmnet cannot hold two rules for one host port.

## Readiness

The guest tells the host when provisioning finishes. The last line of the
first-boot script runs a small `spook-signal` binary that dials the host over
vsock with the script's exit code, so `spook start` prints a definitive result
instead of the host polling for an IP and then for a service and guessing from
a timeout.

If a base predates the signal binary, or nothing is listening, provisioning
still runs — the first-boot logs in the VM's `provision/` directory remain the
record.

## Rebuilding a base

Delete its directory; the next create rebuilds it:

```bash
rm -rf ~/.spooktacular/cache/base/27A5301a
```

Bases are also rebuilt automatically when the bundled provisioner changes, so a
VM never silently inherits a stale one.

## Topics

### Base images

- ``BaseImageStore``
- ``BaseImageDescriptor``
- ``BaseImageBuilder``

### Disks

- ``DiskStack``

### Networking

- ``VmnetNetwork``
- ``GuestNetworkAllocation``
- ``PortPublication``

### Readiness

- ``ProvisioningSignal``
- ``ProvisioningSignalListener``
