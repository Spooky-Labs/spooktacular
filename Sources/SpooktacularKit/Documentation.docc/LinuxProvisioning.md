# Linux Provisioning

Provision Linux guests on first boot with cloud-init — account, SSH, and
first-boot scripts, with no installer walkthrough and no root on the host.

## Overview

Each guest OS has exactly **one** initial-script system, and it runs
user-data **as root on first boot**:

| Concern | macOS guest | Linux guest |
|---|---|---|
| Account, no setup UI, SSH | `VZMacGuestProvisioningOptions` (macOS 27) | cloud-init `users:` + `ssh_pwauth` |
| Root-context script runner | Injected provisioner LaunchDaemon | cloud-init `runcmd` |
| Delivery | Disk-inject at create (**root required**) | `cidata` seed ISO, attached read-only (**no root**) |
| Secret at rest | System-Keychain transient, erased after first boot | SHA-512-crypt **hash** on the seed; seed erased after first boot |

Because nothing on the Linux path mounts a guest disk or touches a
Keychain, provisioned Linux creates run **fully unprivileged** — from the
CLI and from the sandboxed app alike.

## Cloud images, not installer ISOs

Provisioned Linux VMs boot ready-made **cloud images** (which ship with
cloud-init preinstalled):

```bash
# Latest Fedora Cloud aarch64, resolved at create time from
# fedoraproject.org — never a hardcoded version:
spook create dev-box --os linux --from-image fedora

# Latest Debian genericcloud arm64 (cloud.debian.org):
spook create dev-box --os linux --from-image debian

# A local raw image (.raw or .img, optionally .xz-compressed):
spook create dev-box --os linux --from-image ~/images/custom.raw.xz
```

Ubuntu publishes qcow2-only cloud images; convert first
(`qemu-img convert -O raw src.img dst.raw`). The `--installer-iso` flow
remains for manual, unprovisioned installs and provisions nothing.

Downloads cache under `~/.spooktacular/cache/images/`. The image is
materialized as the VM's disk and grown to `--disk` GiB; cloud-init's
`growpart` expands the root filesystem on first boot.

## The account and the seed lifecycle

`--vm-user` (default `admin`) and `--vm-password` (generated and shown
once when omitted) define the guest account. The password enters the seed
**only as a SHA-512-crypt hash** — the `/etc/shadow` posture; plaintext
never touches the host disk. Readable public keys from `~/.ssh` are added
to `ssh_authorized_keys`, and `ssh_pwauth: true` enables password SSH.

At create, Spooktacular renders `user-data`/`meta-data`, packages them
with `hdiutil makehybrid` into a `cidata`-labeled `seed.iso` in the
bundle, and records a non-secret ``PendingProvisioning`` marker in
`metadata.json`. The first `spook start` (or app start) boots plainly —
cloud-init does all the work in-guest — then **erases the seed and clears
the marker**, so the hash doesn't outlive provisioning.

## Templates

- **OpenClaw** (`--openclaw`): Node 24 (newest 24.x from nodejs.org at
  script runtime) into `/usr/local`, `npm -g openclaw@latest`, gateway as
  a systemd unit running as the provisioned user. Port 18789.
- **GitHub Actions runner** (`--github-runner`): same host-side flow as
  macOS — PAT from the Keychain mints a short-lived registration token —
  then in-guest: dedicated `runner` user, latest `linux-arm64` runner
  tarball, `config.sh` (never as root), systemd unit; `--ephemeral`
  supported.

  ```bash
  spook create linux-runner --os linux --from-image fedora \
    --github-runner --github-repo org/repo --github-token-keychain e2e
  spook start linux-runner
  ```
- **Custom** (`--user-data <script>`): your script rides `runcmd`. It
  runs **as root**, before any login session.
- **Remote Desktop**: macOS-only today.

## See Also

- <doc:Provisioning>
- <doc:RemoteDesktop>
- <doc:GitHubActionsGuide>
