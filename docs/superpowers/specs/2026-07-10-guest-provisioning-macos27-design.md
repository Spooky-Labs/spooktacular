# Native guest provisioning on macOS 27 — design

**Status:** Approved design, pre-implementation
**Date:** 2026-07-10
**Branch:** `feat/guest-provisioning-macos27`

## Goal

Replace the fragile Setup Assistant OCR automation with Apple's native
`VZMacGuestProvisioningOptions` (new in macOS 27) so a freshly-installed
ephemeral macOS VM boots straight to a ready state — admin account created,
Setup Assistant skipped — with **zero human interaction, no MDM, and no
screen-scraping**. A single injected root LaunchDaemon then runs the per-VM
`first-boot.sh` locally at boot (no SSH), completing runner / remote-desktop
provisioning.

## Background

The runner use case's provisioning has been the project's weak point. The OCR
approach (drive Setup Assistant by synthesizing keystrokes + reading the screen
with Vision) reached ~step 25 of ~102 in live tests before hitting the next
macOS-26-drifted screen; it is inherently version-fragile.

macOS 27 / Xcode 27 added `VZMacGuestProvisioningOptions`
(`API_AVAILABLE(macos(27.0))`, verified from the macOS 27.0 SDK header). It
configures "a user account and initial setup workflows without manual
intervention during the guest boot process," evaluated **only on the first boot
after restore**. Verified property surface:

```objc
@interface VZMacGuestProvisioningOptions : VZGuestProvisioningOptions <NSCopying>
@property (copy) NSString *fullName;
@property (copy) NSString *username;
@property (copy) NSString *password;
@property BOOL logsInAutomatically;   // auto-login at startup
@property BOOL enablesRemoteLogin;    // enable SSH
@end
```

Attached via `VZMacOSVirtualMachineStartOptions.setGuestProvisioningOptions(_:error:)`
(also macOS 27+). It creates the account and skips Setup Assistant but has **no
"run a script" capability** — so a separate mechanism must run `first-boot.sh`.

## Global constraints

- **Guest OS floor: macOS 27+.** Older guests silently ignore the provisioning
  options. Pre-1.0 rule (no compat hedges): the old OCR path is deleted, not
  kept as a fallback. Ephemeral runner images must be macOS 27+.
- **Non-SSH provisioning trigger.** `first-boot.sh` runs via an injected root
  LaunchDaemon, locally at boot — no network / `sshd` / IP-resolution
  dependency (the exact failure mode that timed out in live testing).
- **Host privilege:** injecting a `root:wheel` LaunchDaemon requires a root file
  operation on the host. On EC2 Mac (the primary target) Spooktacular runs as
  root, so this is direct. On a dev laptop it goes through a one-time privileged
  helper (see Privilege model).
- No force-unwraps; DocC on new public API; Apple-behavior claims verified
  against the SDK header or empirically; TDD for unit-testable logic.

## Architecture

Four cooperating pieces, all triggered from the existing create flow:

```
Create flow (CLI Create.swift / GUI AppState.runMacOSCreate)
  1. VZMacOSInstaller installs macOS 27         (unchanged)
  2. DiskInjector.installProvisionerDaemon(...)  → root LaunchDaemon in image
  3. DiskInjector.inject(script:)                → per-VM first-boot.sh on share (existing)
  4. VirtualMachine.start(provisioning: GuestProvisioningSpec)  → first boot
       └─ sets VZMacGuestProvisioningOptions on start options
  5. guest boots: framework creates admin acct + skips Setup Assistant;
     injected LaunchDaemon runs first-boot.sh as root from the share
  6. host polls GitHub until runner online       (existing)
```

### Component 1 — `GuestProvisioningSpec` (SpooktacularCore, new)

A Foundation-only value type describing what the framework should provision.
Pure domain type; no Virtualization import (keeps Core framework-free).

```swift
public struct GuestProvisioningSpec: Sendable, Equatable {
    public var fullName: String       // e.g. "Spooktacular Runner"
    public var username: String       // e.g. "runner"
    public var password: String       // ephemeral, generated per-VM
    public var logsInAutomatically: Bool  // see default below
    public var enablesRemoteLogin: Bool   // SSH; default false (daemon path doesn't need it)
    public init(...)
}
```

**Defaults, made explicit (no ambiguity):** for both runner and remote-desktop
creates, `logsInAutomatically = true`. A live Aqua session is required for
remote desktop and for runner jobs that run UI tests, and it is harmless for
headless runner jobs — so we always auto-login rather than branch on job type.
`enablesRemoteLogin = false` by default (the LaunchDaemon path needs no SSH);
the create flow may set it `true` when the user wants SSH access for debugging.

- **Password generation** lives in the create flow (a `SecRandomCopyBytes`-backed
  helper), not in this type — the type just carries it.
- Unit-testable: validation (non-empty username, password length/charset the
  framework accepts — to be confirmed empirically, see Verification).

### Component 2 — `VirtualMachine.start` provisioning hook (SpooktacularInfrastructureApple, modify)

`VirtualMachine.start(...)` already builds `VZMacOSVirtualMachineStartOptions`
(line ~332). Add an optional parameter carrying the spec; when present and the
host is macOS 27+, translate it to `VZMacGuestProvisioningOptions` and attach it.

```swift
public func start(
    startUpFromMacOSRecovery: Bool = false,
    guestProvisioning: GuestProvisioningSpec? = nil
) async throws
```

- Uses `if #available(macOS 27, *)` around `setGuestProvisioningOptions`; if the
  spec is non-nil on an older **host**, throw a clear error (host must be 27+ to
  set the options — separate from the guest 27+ requirement).
- The spec→`VZMacGuestProvisioningOptions` mapping is a small pure function
  (unit-testable via a thin seam, since `VZMacGuestProvisioningOptions` is a
  plain value object we can construct and read back its properties in a test).
- The options are set on the **first** post-install boot only (the framework
  ignores them afterward); the create flow calls `start(guestProvisioning:)`
  exactly once, then subsequent starts pass `nil`.

### Component 3 — Provisioner LaunchDaemon injection (SpooktacularInfrastructureApple, modify DiskInjector + Resources)

A **single static** LaunchDaemon replaces the SpookProvisioner pkg. Its plist +
runner script are shipped in `Resources/SpookProvisioner/` (reuse the existing
files, drop the pkg `postinstall`). `DiskInjector` gains:

```swift
public static func installProvisionerDaemon(
    into bundle: VirtualMachineBundle,
    privileged: PrivilegedFileOps
) throws
```

Steps: attach `disk.img` (existing `diskutil image attach --nomount`), mount the
Data volume, copy `com.spooktacular.provisioner.plist` →
`<vol>/Library/LaunchDaemons/` and the runner script →
`<vol>/usr/local/libexec/`, `chown root:wheel` + `chmod 644`/`755` **via
`privileged`**, unmount, detach.

The runner script (already exists, `spook-provision-runner.sh`): on boot,
`mount_virtiofs spook-provision <mnt>`, run `<mnt>/first-boot.sh` as root once,
archive + clear the trigger. It is version-stable (fixed file contracts +
`mount_virtiofs`/`launchctl`). `RunAtLoad=true`, `KeepAlive=false`.

- `first-boot.sh` must be resilient to running before the framework finishes
  creating the `runner` account: it waits (bounded) for the account to exist
  (`id runner`) before any `sudo -u runner` step, then proceeds. The runner
  config (`config.sh`, service install via `launchctl bootstrap`) already runs
  as `sudo -u runner` per `GitHubRunnerTemplate` — unchanged.

### Component 4 — `PrivilegedFileOps` (new, SpooktacularInfrastructureApple)

The one genuinely new infra seam: perform the `chown root:wheel` (and the
`mkdir`/copy that need root on the guest volume) with a privilege abstraction.

```swift
public protocol PrivilegedFileOps: Sendable {
    func chownRoot(_ url: URL) throws
    func copy(_ src: URL, to dst: URL, mode: mode_t, ownerRoot: Bool) throws
}
```

- **`DirectPrivilegedFileOps`** — used when `geteuid() == 0` (EC2 Mac / running
  under a root LaunchDaemon). Calls `chown`/`chmod`/`copyfile` directly. This is
  the primary, shipped-first implementation.
- **`HelperPrivilegedFileOps`** — a one-time-installed `SMAppService` daemon for
  dev laptops (single admin approval at install, never per-VM). Designed here;
  built as its own plan task. If neither root nor helper is available, the create
  command fails fast with an actionable message.

## Data flow (runner, end to end)

1. `spook create runner-01 --github-runner --github-repo o/r --github-token-keychain acct`
2. Resolve PAT; install macOS 27 into the bundle.
3. Generate ephemeral password; build `GuestProvisioningSpec(username: "runner",
   password: <rand>, logsInAutomatically: true)`.
4. `DiskInjector.installProvisionerDaemon(into:privileged:)` — root LaunchDaemon
   into the image.
5. Mint GitHub registration token (late); render `first-boot.sh` from
   `GitHubRunnerTemplate`; `DiskInjector.inject(script:)` onto the share.
6. `vm.start(guestProvisioning: spec)` — first boot. Framework creates the admin
   `runner` account, skips Setup Assistant; the LaunchDaemon runs `first-boot.sh`
   as root, which waits for the account, then configures + starts the runner as
   `runner`.
7. Host polls GitHub until `runner-01` is `online`; leaves the VM running.

Remote desktop is the same mechanism with a `RemoteDesktopTemplate` first-boot
script and `logsInAutomatically: true` (a live Aqua session for screen sharing).

## What gets deleted

The entire OCR + pkg provisioning surface:

- `Sources/SpooktacularApplication/SetupAutomation.swift` (920)
- `Sources/SpooktacularInfrastructureApple/SetupAutomationExecutor.swift` (578)
- `Sources/SpooktacularInfrastructureApple/VZKeyboardDriver.swift` (382)
- `Sources/SpooktacularInfrastructureApple/VZScreenReader.swift` (250)
- `Sources/SpooktacularCore/ScreenReader.swift`, `KeyboardDriver.swift` (protocols)
- `Sources/SpooktacularGuestTools/ProvisionerInstaller.swift` (148) + the pkg-install path
- `Resources/SpookProvisioner/postinstall` (pkg script — no longer a pkg)
- `build-app.sh` provisioner-pkg assembly (`pkgbuild`/`productbuild` of the pkg)
- Their tests (SetupAutomation/executor/gate tests, screenshot-diagnostic code)
- Any Create.swift/AppState references to `automateSetupAssistant`,
  `installProvisioner`, the screen-gate flow, and the `RunnerCreateFlowPlan`
  branches that gate on Setup Assistant support.

Kept: `DiskInjector` (trimmed to disk mount + file write + chown), the
`spook-provision` virtio-fs share, `spook-provision-runner.sh`, the provisioner
plist, `GitHubRunnerTemplate`, `IPResolver` (still used for `spook ip` / online
status), the runner online-poll.

## Error handling

- Host < macOS 27 with a non-nil spec → typed error at `start`, clear message.
- `PrivilegedFileOps` unavailable (not root, no helper) → fail fast before
  install with an actionable message.
- Guest volume not mountable / already FileVault-sealed → existing
  `DiskInjectorError` cases (`mountFailed`, `guestVolumeEncrypted`).
- `first-boot.sh` account-wait timeout → the daemon logs to
  `/var/log/spooktacular-provisioner*.log`; runner online-poll ultimately reports
  failure with the non-zero exit-code contract already in the create flow.

## Testing & verification

**Unit (TDD):** `GuestProvisioningSpec` validation; the
spec→`VZMacGuestProvisioningOptions` mapping (construct, read back properties);
`DirectPrivilegedFileOps` file-op semantics against a temp dir (skip the
`ownerRoot` assertion unless the test runs as root); provisioner-plist/runner-
script contract tests (RunAtLoad, mount tag, account-wait present).

**Empirical (macOS 27 beta — verify, don't extrapolate). This is the
verify-before-delete gate — do it before deleting the OCR path:**

1. Download a **macOS 27 guest IPSW** (only 26.4.1 is cached).
2. One live create with `VZMacGuestProvisioningOptions` set, and confirm:
   - the framework-created `runner` user **is an admin** (`sudo` works);
   - Setup Assistant is skipped to a usable state (no login-wall stall);
   - the injected LaunchDaemon runs `first-boot.sh` (check the log);
   - framework account-creation and the daemon **coexist on first boot** without
     a fatal race (the account-wait in `first-boot.sh` covers ordering);
   - `logsInAutomatically`/`enablesRemoteLogin` behave as the header claims.
3. Only after this passes: delete the OCR stack.

**Live e2e:** full `spook create --github-runner` on macOS 27 → a real GitHub
job runs on the ephemeral runner (the milestone the OCR path never reached).

## Sequencing

1. Verify the beta API on a macOS 27 guest (download IPSW; minimal harness).
2. Build the new path (Components 1–4) behind the create flow, keeping the OCR
   path temporarily so the tree stays green.
3. Live e2e green on macOS 27.
4. Delete the OCR/pkg surface; re-green build + tests + CI.
5. README/docs truth pass for the new provisioning model.

## Out of scope

- macOS ≤26 guest provisioning (deleted, not supported).
- The `HelperPrivilegedFileOps` SMAppService helper is designed here but is its
  own plan task; the first shippable increment targets root-on-EC2-Mac
  (`DirectPrivilegedFileOps`).
- Multi-tenant / control-plane concerns (separate pending decision).

## Verification results

**Status: VERIFIED** — all four Phase-1 facts confirmed empirically on a live
macOS 27 guest. This is the verify-before-delete gate for Phase 4.

**Date:** 2026-07-10. **Host:** macOS 27.0 (26A5378j), SDK 27.0, Mac14,2
(Apple silicon). **Method:** throwaway, virtualization-entitlement-signed Swift
harness (not committed to `Sources/`) that installed macOS 27 into a temp bundle
via `VZMacOSInstaller`, then booted headless with
`VZMacOSVirtualMachineStartOptions.setGuestProvisioning(_:)` carrying
`VZMacGuestProvisioningOptions(username: "probe", password: <random>,
fullName: "Probe", logsInAutomatically: true, enablesRemoteLogin: true)`. VM
reached the network in ~12 s and sshd in ~48 s; verification was over
password SSH (`probe@192.168.64.101`), IP resolved from `/var/db/dhcpd_leases`.

**Guest IPSW:** macOS 27.0 beta 3, build **26A5378j**
(`UniversalMac_27.0_26A5378j_Restore.ipsw`, 22,567,352,533 bytes,
SHA1 `38d473d910d99d53a635a3a6971248d55f1ec257` — matches Apple's CDN
`x-amz-meta-digest-sh1`). Cached at
`~/.spooktacular/cache/ipsw/UniversalMac_27.0_26A5378j_Restore.ipsw`.

> **IPSW-acquisition caveat (affects the real create flow):**
> `VZMacOSRestoreImage.latestSupported` returned **macOS 26.5.2 (25F84)**, not
> 27 — Apple's `latestSupported` / the public
> `com_apple_macOSIPSW.xml` catalog track the latest *release*, not the
> installed *beta*. The macOS 27 beta IPSW is not served through
> `latestSupported`; it must be fetched from the seed CDN URL directly
> (`softwareupdate --fetch-full-installer` only yields an installer app, not an
> IPSW usable by `VZMacOSInstaller`). The later e2e/CLI work must not rely on
> `latestSupported` to obtain a 27 guest — pass an explicit
> `--from-ipsw`/local path.

**setGuestProvisioning accepted the options** (validation passed;
`startOptions.guestProvisioningOptions?.username` read back `"probe"`) —
`GUEST_PROVISIONING_SET username=probe logsInAutomatically=true enablesRemoteLogin=true`.

### Fact 1 — framework-created user is an admin: **CONFIRMED**

`id probe` includes `80(admin)`; `sudo -v` → succeeded (`SUDO_V_OK`);
`sudo id` → `uid=0(root) gid=0(wheel) …`. The framework-provisioned account has
full admin/sudo.

### Fact 2 — Setup Assistant skipped to a usable state: **CONFIRMED**

`/var/db/.AppleSetupDone` present (`root:wheel`, born 04:39:40, ~T+105 s after
the 04:37:55 boot); `autoLoginUser = probe`; a live Aqua session
(`who` → `probe console`, with `Dock` (pid 679), `Finder` (683), and
`loginwindow` (107) all running). No login-wall stall — SSH and an
auto-logged-in desktop were both reachable. (Two `Setup Assistant.app` *migration/backup*
background helpers — `mbsystemadministration`, `mbbackgrounduseragent` — were
present but are not the interactive setup wall; `.AppleSetupDone` + the live
console session prove setup is complete.)

### Fact 3 — `enablesRemoteLogin` actually enables sshd: **CONFIRMED**

Port 22 opened ~48 s after boot; password SSH succeeded; explicit
`systemsetup -getremotelogin` → **`Remote Login: On`**. Setting
`enablesRemoteLogin = true` turns on Remote Login/sshd.

### Fact 4 — a `RunAtLoad` root LaunchDaemon coexists with framework provisioning: **CONFIRMED**

A trivial `RunAtLoad` daemon (`/Library/LaunchDaemons/com.spook.probe.plist`,
`root:wheel` 0644 → `/usr/local/libexec/spook-probe.sh`, `root:wheel` 0755) was
installed and the VM rebooted. After reboot (new boot time 04:43:49, later than
the original 04:37:55 — a real reboot), `/var/tmp/spook-daemon-ran` existed with:

```
Fri Jul 10 04:44:22 PDT 2026
uid=0(root) gid=0(wheel) groups=0(wheel),1(daemon),…,20(staff),80(admin),…
boottime: { sec = 1783683829, … } Fri Jul 10 04:43:49 2026
```

The daemon **ran as `uid=0(root)`**, and the framework-provisioned account
**persisted and stayed admin** (`id probe` → `80(admin)`), with auto-login
re-established (`who` → `probe console`). Framework account-creation and a
`RunAtLoad` root daemon coexist; both run on boot.

**Daemon-vs-account timing (informs the `first-boot.sh` account-wait):** on the
**first** boot the framework created the `probe` account late — home dir born
04:38:49 (**~T+54 s** after the 04:37:55 boot), dslocal plist finalized 04:41:10.
A `RunAtLoad` daemon fires early in boot (the injected probe ran at **~T+33 s**
post-reboot; stock `RunAtLoad` daemons run in the first seconds). **Therefore a
`RunAtLoad` daemon fires BEFORE the framework account exists on first boot** —
confirming the design's bounded account-wait in `spook-provision-runner.sh` /
`first-boot.sh` is necessary (Plan Task 5, Step 5).

### Harness-signing note (for the later e2e/CLI signing)

Signing the harness with the full app entitlements file
(`Spooktacular.entitlements`, which carries
`com.apple.application-identifier` + `com.apple.developer.team-identifier`)
made the *bare CLI* binary hang at launch (no provisioning profile embedded) —
process stuck before `main`, killed by watchdog. Re-signing with a
virtualization-only entitlements plist (just `com.apple.security.virtualization`,
which is the only entitlement `VZVirtualMachine`/`VZMacOSInstaller`/
`VZMacGuestProvisioningOptions` actually require) fixed it and the harness used
Virtualization normally. Identity used: the same `Apple Development:` cert
`build-app.sh` resolves. Takeaway: a standalone CLI/helper needs only the
virtualization entitlement, not the app-identifier keys.

### Pre-boot injection vs. in-guest injection (scope note)

The harness could not perform the *host-side, pre-first-boot* daemon injection
(mount the installed Data volume + `chown root:wheel`) because that needs host
root and passwordless `sudo` was unavailable in this automated run. Fact 4 was
instead proven by installing the same `root:wheel` `RunAtLoad` daemon in-guest
(via the provisioned admin's `sudo`) and rebooting — which demonstrates the
identical runtime property (a `root:wheel` `RunAtLoad` daemon runs as root and
coexists with the provisioned account). The first-boot *ordering* is
established from the timestamp evidence above (account @ ~T+54 s vs. RunAtLoad @
~T+33 s). The production `DirectPrivilegedFileOps` path (Plan Task 4/6) requires
`geteuid() == 0`, which is satisfied on EC2 Mac / under the root service, and is
exercised end-to-end in Phase 3 (Task 10).
