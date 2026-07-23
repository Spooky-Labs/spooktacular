# Cross-OS First-Boot Provisioning — Design

**Date:** 2026-07-18
**Status:** Draft for review

## Goal

Every provisioning template — GitHub Actions runner, OpenClaw AI Agent,
Remote Desktop, Custom Script — works out of the box on **macOS guests and
Linux guests**, from **both the CLI and the GUI**, with no golden image and
no SSH round-trip.

**Deployment reality this design serves:**

- **Production:** `spook` runs as a root service on EC2 Mac. Everything
  root-dependent is normal there.
- **Local:** developers validate the project on their own Mac before
  trusting it in production. Local must work — as a user in the GUI, and
  via `sudo` in the CLI. The GUI may **ask for root at runtime** when an
  operation needs it.

## Principle

Each guest OS has exactly **one** initial-script system, and it runs
user-data **as root inside the guest on first boot**. No SSH anywhere in
first-boot provisioning.

| Concern | macOS guest (exists, hardware-verified) | Linux guest (this design) |
|---|---|---|
| Account, no Setup Assistant, SSH | `VZMacGuestProvisioningOptions` at first start (macOS 27 host+guest) | cloud-init `users:` + `ssh_pwauth` from the seed |
| Root-context script runner | Injected provisioner LaunchDaemon runs `first-boot.sh` as root (`DiskInjector`) | **cloud-init itself** (`runcmd`) — preinstalled in every cloud image |
| Delivery | Disk-inject at create (requires root) | `cidata` seed ISO attached read-only (**no root required**) |
| Secret handling | Password transits the System Keychain, erased after first boot (shipped `e045f24e`) | Password stored **only as a SHA-512-crypt hash** in seed user-data; seed scrubbed after first successful boot |

There is no Linux equivalent of `VZMacGuestProvisioningOptions` — verified
against Apple docs and the MacOSX27.0 SDK (`VZGuestProvisioningOptions` has
one subclass, macOS-only, hanging off `VZMacOSVirtualMachineStartOptions`).
cloud-init is Linux's native equivalent and additionally runs scripts.

## Workstream 1 — Fix the macOS OpenClaw template (root-context bug)

`OpenClawTemplate.scriptContent()` currently begins with the Homebrew
installer. The provisioner daemon runs `first-boot.sh` **as root**
(`DiskInjector.swift:139`), and Homebrew's installer refuses to run as
root — the flow dies at step 1. (`--remote-desktop` works because its
script is pure root-context commands; hardware-verified 2026-07-17.)

Rewrite the macOS template for root context:

1. Install Node 24 from the official nodejs.org arm64 `.pkg` via
   `installer -pkg` (root-native; resolve the latest 24.x at script
   runtime from nodejs.org's release index, never hardcoded).
2. `npm install -g openclaw@latest`.
3. Configure the gateway to run for the provisioned user (launchd job
   owned by the account created by native provisioning; the script waits
   for that account to exist before configuring per-user pieces).
4. Same audit for the Custom Script docs: state plainly that user-data
   runs as root at first boot, before any user session.

## Workstream 2 — Linux cloud-image + cloud-init pipeline

New components (all host-side, all rootless):

- **`--from-image <path|alias>`** on `spook create --os linux`: accepts a
  local raw disk image (`.raw`, raw `.img`, `.raw.xz` — xz decoded via
  Apple's Compression framework, LZMA/xz support to be doc-verified during
  implementation) or an alias (`fedora`, `debian`) resolved **at runtime**
  against the distro's official release endpoint to the latest aarch64
  cloud image. Never a hardcoded version. Ubuntu ships qcow2-only cloud
  images; qcow2 conversion is out of scope day one — clear error with a
  `qemu-img convert` hint.
- **`CloudInitSeed`** (SpooktacularApplication): generates `user-data`
  (#cloud-config: user from `--vm-user`, `passwd:` as SHA-512-crypt hash,
  `ssh_pwauth: true`, host user's `~/.ssh/*.pub` if present, template
  script in `runcmd`) and `meta-data` (instance-id = VM UUID, hostname =
  VM name), builds `seed.iso` with `hdiutil makehybrid -iso -joliet
  -default-volume-name cidata`.
- **SHA-512-crypt (`$6$`)** implementation in Swift (no third-party deps),
  TDD'd against published reference vectors.
- **Config attach:** `VirtualMachineConfiguration` attaches `seed.iso`
  read-only via the existing `VZDiskImageStorageDeviceAttachment` pattern
  when the bundle contains one.
- **Image sizing:** copy/decompress the cloud image into the bundle as the
  primary disk, then grow the file to `--disk` size; cloud-init's growpart
  expands the root filesystem on first boot.
- **Lifecycle parity with macOS:** metadata gets the same
  `pendingProvisioning` marker; the first successful `spook start` (or GUI
  start) deletes `seed.iso` and clears the marker. The password hash never
  outlives first boot; plaintext never touches disk at all.

The installer-ISO flow (`--installer-iso`) remains only for unprovisioned,
manual Linux VMs.

## Workstream 3 — OS-aware templates

`ProvisioningTemplate` scripts gain a `GuestOS` dimension:

- **OpenClaw (Linux):** official Node 24 linux-arm64 tarball into
  `/usr/local`, `npm -g openclaw@latest`, gateway as a systemd unit
  running as the provisioned user.
- **GitHub runner (Linux):** actions-runner linux-arm64 tarball, systemd
  unit, registration via the **existing** token-minting path (PAT in
  Keychain → short-lived registration token embedded in user-data;
  `--ephemeral` supported). Host-side flow mirrors the macOS runner flow.
- **Remote Desktop:** macOS-only this round (Linux desktop+RDP is a
  follow-up; the GUI/CLI label it accordingly).
- **Custom Script:** works on both; docs state the root-at-first-boot
  contract for each OS.

## Workstream 4 — GUI

1. **Root-cause the greyed provisioning picker** (live repro +
   instrumentation, systematic-debugging process; every template option is
   currently disabled even for macOS guests — cause unknown, no
   `.disabled` in code).
2. **Linux guests get the Provisioning section** (currently hidden behind
   `guestOS == .macOS`). Rootless cloud-init means Linux templates work
   fully from the sandboxed GUI with no escalation.
3. **macOS templates from the GUI escalate at runtime:** privileged helper
   registered via `SMAppService.daemon` (one-time admin approval in System
   Settings), XPC service exposing exactly one operation: disk-inject of
   provisioner + first-boot.sh into a not-yet-booted guest image. API
   shape to be verified against Apple docs during planning. Until approved
   (or if declined), the GUI shows the exact `sudo spook create …`
   equivalent as the fallback path.

## Workstream 5 — CLI ergonomics

Non-root `spook create` with a macOS template keeps the current fail-fast
`provisioner-requires-root` error + sudo hint (production is a root
service; local CLI users get told exactly what to run). Linux creates run
fully unprivileged.

## Security invariants

- No plaintext guest password at rest, either OS (macOS: System-Keychain
  transient, unchanged; Linux: SHA-512-crypt hash on the seed, scrubbed
  after first boot).
- No new always-on privileged surface: the helper daemon does one
  operation, requires explicit admin approval, and disk-inject remains
  impossible from the sandbox without it.
- Credentials print once at create; `--json` carries them structured.

## Testing

- Unit (TDD): sha512-crypt reference vectors; seed user-data/meta-data
  content (account, hash-not-plaintext assertion, runcmd payload);
  image-alias resolver against recorded endpoint fixtures; per-OS template
  content assertions (macOS openclaw contains no `brew`, Linux runner unit
  file well-formed); marker/seed lifecycle round-trip.
- Live validation: Fedora + Debian aarch64 boot with account+SSH+script
  (minutes, rootless — cheap); macOS `--openclaw` re-run under sudo on
  this Mac; Linux runner registers against a real repo and shows online.
- All Apple API claims (SMAppService, Compression/xz, hdiutil flags)
  doc-verified or empirically tested during implementation, cited in code
  comments.

## Out of scope (this round)

Ubuntu qcow2 images; Remote Desktop on Linux; changes to the macOS runner
flow, keychain design, or per-action MFA gate (the MFA-under-root dead end
for `spook delete` is a known separate issue); Intel hosts.
