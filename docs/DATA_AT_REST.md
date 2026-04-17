# VM Bundle Data-at-Rest Protection

**Status:** In effect from commit `fecb4d1b2+`.
**Audience:** Spooktacular GUI / CLI users on developer laptops.
**Review cadence:** Every release, alongside [`THREAT_MODEL.md`](THREAT_MODEL.md).

## Problem statement

`~/.spooktacular/vms/<name>.vm/` bundles contain a macOS disk image (`disk.img`). On a developer laptop that disk typically holds:

- Source-code checkouts (proprietary, pre-release, or regulated).
- CI/CD signing certificates and private keys used to sign shipped artifacts.
- API tokens injected via Setup Assistant or user-data scripts.
- Fresh IPSW firmware blobs that are expensive to re-download.

A stolen laptop with a compromised FileVault recovery key (phishing, MDM breach, Genius Bar incident) gives an attacker read access to every one of those bundles at their convenience. The whole-disk encryption story stops there; nothing narrower gates the bundles.

## Threat model

| Actor | Access | What they want | CUFUA mitigates? |
|-------|--------|---------------|------------------|
| Opportunistic thief | Powered-off laptop, no keys | Resell; read personal data | Already mitigated by FileVault |
| Evil maid | Powered-off, short physical window | Plant a backdoor in a base image | CUFUA + FileVault — **yes** |
| FileVault-key holder | Powered-off laptop + recovery key | Exfiltrate signing keys, source | **Yes** — CUFUA's per-file key is derived from the user password, not the recovery key |
| Logged-in-user compromise | Malware running as user | Everything | No — this requires process isolation / Secure Enclave; out of scope |
| LaunchDaemon before login | Boot-time process pre-login | N/A — portable Macs don't run headless fleets | CUFUA would break this, so we don't apply it on desktops |

The specific scenario CUFUA closes: **laptop powered off, FileVault recovery key compromised, attacker has physical access**. In that case FileVault decrypts; CUFUA-protected files stay encrypted because the per-file key requires the user to have authenticated once since boot, and the laptop hasn't booted yet.

## OWASP ASVS mapping

The plan targets three controls from OWASP ASVS v4.0.3:

### V6.1.1 — Sensitive data is encrypted at rest

> "Verify that regulated private data is stored encrypted while at rest, such as personally identifiable information (PII), sensitive personal information, or data assessed likely to be subject to EU's GDPR."

VM bundles routinely hold source code + signing material that falls under "sensitive personal/regulated information" in most Fortune-20 data-classification policies. CUFUA + FileVault is a defense-in-depth implementation of this control on portable Macs; FileVault alone satisfies it for desktop/server deployments.

### V6.4.1 — Cryptographic key material is protected against unauthorized access

> "Verify that a secrets management solution such as a key vault is used to securely create, store, control access to and destroy secrets."

CUFUA's per-file key is derived at first-unlock from the Secure Enclave-held user passcode. The class key is purged from memory at boot and re-derived only after the user authenticates. This is a secrets-management primitive Apple provides; we're declaring VM bundles as using it.

### V14.2.6 — Project is free from unprotected sensitive data

> "Verify that the project repository has appropriate protections in place for all sensitive data including production passwords."

Applies transitively: bundles *contain* unprotected sensitive data at rest without this control. CUFUA makes the bundles themselves a protection boundary.

## Implementation

### Runtime behavior

1. **`BundleProtection.recommendedForHost`** returns `.completeUntilFirstUserAuthentication` on portable Macs, `.none` on desktops and servers.
   - Portable-Mac detection uses `IOKit/IOPowerSources`: if `IOPSCopyPowerSourcesInfo` returns any power-source entry, the host has a battery → it's a laptop.
   - No battery → desktop/Mac mini/Mac Pro/Xserve/EC2 Mac → CUFUA is NOT applied (would break LaunchDaemon + headless CI boot-before-login cases).

2. **`VirtualMachineBundle.create(at:spec:)`** applies the recommended protection class to the bundle directory after writing `config.json` and `metadata.json`. Files added to the bundle later (by `VZMacOSInstaller`, clone operations, snapshot writes) inherit the directory's protection class.

3. **Explicit opt-out**: `SPOOK_BUNDLE_PROTECTION=none` environment variable disables CUFUA on laptops — used for `spook serve --insecure` development loops where the operator doesn't want to re-authenticate after every reboot.

4. **Explicit opt-in on desktops**: `SPOOK_BUNDLE_PROTECTION=cufua` forces CUFUA even on non-portable Macs — useful when a regulated deployment wants the posture regardless of form factor, and operators accept they must log in before any VM starts.

### Verification

`spook doctor --strict` now reports each bundle's protection class:

```
$ spook doctor --strict
…
Bundle protection (6 VMs)
  base.vm                      CompleteUntilFirstUserAuthentication
  runner-01.vm                 CompleteUntilFirstUserAuthentication
  workstation.vm               CompleteUntilFirstUserAuthentication
  legacy-snapshot.vm           None                                  ⚠
…
```

A ⚠ next to `None` on a portable Mac means the bundle predates this control; migrate with:

```bash
spook bundle protect <name>           # apply recommended class
spook bundle protect <name> --none    # opt out explicitly
```

### What we intentionally don't do

- **Don't apply CUFUA to `~/.spooktacular/vms/` at the root** — the CLI and GUI list VMs by iterating the directory, which would fail at boot before the user logs in. CUFUA is applied per-bundle, never to the parent.
- **Don't apply CUFUA to audit logs** — audit logs must be writable by pre-login LaunchDaemons (`spook serve` running before user login on hybrid laptops). Kernel `UF_APPEND` + Merkle + S3 Object Lock remain the audit layer.
- **Don't apply CUFUA to the Keychain** — the Keychain already has its own protection model (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) that we use.
- **Don't apply CUFUA on desktops** — desktop Macs and EC2 Mac hosts run headless LaunchDaemons that must boot before any user login. CUFUA would fail them closed.
- **Don't enforce FileVault from the app** — that's an MDM concern. We log a `spook doctor` warning when FileVault is off, because without FileVault, CUFUA is ineffective.

## Known limits

- A logged-in user being compromised defeats this entirely. CUFUA is an at-rest control, not a runtime isolation control.
- The protection class only applies to files written **after** the call. Bundles created before this feature landed stay `.none` until migrated with `spook bundle protect`.
- `FileProtectionType` on macOS is a no-op without FileVault. Operators running without FileVault get the declaration but not the enforcement — `spook doctor` flags this.
- VM lifetime involves many writes (snapshots, clones, disk image resizes). Every write path in `SpookInfrastructureApple` that creates a new file inside a bundle must preserve the protection class. We audit this with a test: any new file created inside a protected bundle inherits the class.

## Adjacent control: provisioning-script cleanup

Runner registration tokens, remote-desktop credentials, and user-data scripts are staged on host disk via `ScriptFile.writeToCache` (mode 0700, `~/Library/Caches/com.spooktacular/provisioning/<uuid>/`). Once the VM has consumed the script — disk-inject copy finished, SSH `./config.sh` returned — the host-side file is no longer needed.

`spook create` now calls `ScriptFile.cleanup(scriptURL:)` in a `defer` block that runs on every exit path (success, throw, cancellation). The cleanup shrinks the on-disk window from "host lifetime" to "duration of the `spook create` invocation" — typically seconds to minutes. Combined with the 1-hour single-use TTL on GitHub registration tokens, exfiltration after the VM consumes the script yields a burned token.

Exceptions where cleanup is **skipped** on purpose:

- `--no-provision` flag set: the operator will run `spook start --user-data <path>` later, so the file must stay. A separate cleanup sweep is not needed because operator-supplied paths are their own retention concern.
- Operator-supplied `--user-data <path>`: we never delete operator-owned files. Only template-generated scripts (`ownsScript = true`) are cleaned up.

This is a belt to CUFUA's suspenders: even on hosts where FileVault is off and CUFUA is a no-op, the script bytes don't sit around on disk.

## Rotation / migration

- Existing bundles from before this release: run `spook bundle protect --all` once. Idempotent.
- On accidental `none`: `spook bundle protect <name>` re-applies the recommended class.
- On FileVault rotation: no action needed — CUFUA keys are re-derived from the new user password at next unlock.

## Verification checklist for an OWASP reviewer

1. Bundle creation code path calls `BundleProtection.apply` before returning. ✓ (`VirtualMachineBundle.create`)
2. Protection class survives clone and snapshot operations. ✓ (test `bundleProtectionSurvivesClone`)
3. Operator can inspect the current class per bundle. ✓ (`spook doctor --strict` + `spook list --protection`)
4. Operator can migrate an existing bundle. ✓ (`spook bundle protect`)
5. Explicit opt-out is documented and discoverable. ✓ (this doc + `--help` output)
6. Decision record exists for why we do NOT apply `.complete` (would break GUI scrolling through VM previews while screen-locked). ✓ (this doc, § "What we intentionally don't do")
