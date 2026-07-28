# Instant macOS VM Creation: ASIF Base + Overlay, vmnet Ports, vsock Readiness — Design

**Date:** 2026-07-28
**Status:** Draft for review
**Task:** #16

## Problem

Creating a macOS VM today costs 10–20 minutes (per-VM `VZMacOSInstaller` run) and
requires host root at create time (mounting the guest disk to inject the
provisioner LaunchDaemon). Guest services (the OpenClaw gateway on `:18789`)
have no stable host-side address, `spook ip` parses DHCP lease files, and
"provisioning finished" is inferred by polling. Every one of these has a
first-class Apple API answer on our macOS 27 baseline.

## Requirements (locked during brainstorming)

1. **Scope: macOS guests only.** The Linux cloud-image flow (cached image +
   cloud-init seed, rootless) is untouched.
2. **Base acquisition is implicit** and rides the existing IPSW pipeline:
   `VZMacOSRestoreImage.latestSupported` ("get most recent") or an
   operator-supplied local IPSW. First macOS create builds the base; no new
   mandatory commands.
3. **Templates stay a per-VM choice** in GUI and CLI (`--github-runner`,
   `--openclaw`, `--remote-desktop`, `--user-data`). A runner VM must "just
   work"; an OpenClaw VM's gateway must be reachable **on the host at a stable
   port**.
4. Existing hard rules apply: no golden images requiring manual setup, no
   plaintext guest passwords at rest, no timeout-race polling, documented APIs
   only, pre-1.0 ships one design (no dual modes, no migration shims).

## Architecture

Four concepts. Everything else is rewiring.

### 1. Base Store — install once, root once

`~/.spooktacular/cache/base/<macOS-build>/`, sibling to the IPSW cache:

| File | Content |
|---|---|
| `base.asif` | macOS installed by `VZMacOSInstaller`, provisioner shim + `spook-signal` injected, **never booted**, sealed `chmod a-w` |
| `auxiliary.bin` | post-install NVRAM/boot state (template for per-VM clonefiles) |
| `hardware-model.bin` | `VZMacHardwareModel` captured at build |
| `metadata.json` | source IPSW SHA256, shim version, base `layerUUID`, created date |

Build is implicit on the first macOS create: resolve IPSW (unchanged) →
`diskutil image create blank --fs none --format ASIF` → install → inject shim
via `DiskInjector.installProvisionerDaemon` (**the only root/privileged-helper
moment in the system**) → capture `layerUUID` → seal → atomic rename into the
store. An `O_EXLOCK` file lock serializes concurrent builds; the loser waits on
the winner's progress.

The base is *not* a golden image in the banned sense: it is built unattended by
the app from Apple's installer, reproducible from `metadata.json`, and contains
no accounts, no user state, and no manual steps.

### 2. Overlay-backed VM bundles — create in seconds, rootless

macOS bundles replace `disk.img` with:

- `disk-overlay.asif` — created empty at bundle creation
- metadata gains `base: {path, layerUUID}` and `publications: [PortPublication]`
- per-VM identity as today: fresh `VZMacMachineIdentifier()`, clonefile'd
  `auxiliary.bin` (APFS `copyItem` — instant), generated MAC, reserved IP

**Empirical gate (aux-storage cloning):** Apple documents only that two
*concurrent* VMs must not share a machine identifier
(`VZMacPlatformConfiguration.machineIdentifier`); the docs are silent on
pairing a cloned `auxiliary.bin` with a fresh identifier. Tart ships
aux-copying in production (with the identifier also copied), which corroborates
aux portability but not our exact combination. The first live boot in
implementation validates it; the documented fallback if a clone refuses to
boot is recreating aux via `VZMacAuxiliaryStorage(creating:hardwareModel:)`
and re-running the installer's first-boot path against the overlay — to be
designed only if the gate fails.

Layer-creation configurations "can only be used with stacking operations"
(DocC: `ASIFLayerCreationConfiguration`) — an overlay cannot be created
standalone. It is therefore born at bundle-create time by appending it to the
opened base (which also records its `parentUUID` lineage), and opened +
appended as an existing layer on every subsequent start:

```swift
// bundle create (once): materialize the overlay by appending it to the base.
// `.overlay` inherits the base's size; `.overlay(blockCount:)` resizes the
// stack — this is how a per-VM `--disk` larger than the base is honored.
let base  = try DiskImage(opening: .open(url: store.baseURL, mode: .readOnly))
_ = try base.appending(.asifLayer(url: bundle.overlayURL, type: overlayType))

// start (every boot): open base read-only, append the existing overlay
let base    = try DiskImage(opening: .open(url: store.baseURL, mode: .readOnly))
let overlay = try DiskImage(opening: .open(url: bundle.overlayURL))
let stack   = try base.appending(overlay)
let disk    = try VZDiskImageStorageDeviceAttachment(diskImage: stack)   // .automatic caching, .full sync defaults
```

Guard before attach: `base.layerUUID == metadata.base.layerUUID`; mismatch is a
typed `BaseDriftError` ("base image changed since this VM was created").
The framework enforces the same invariant itself via `parentUUID` lineage
(`IncompatibleStackingError`) — our check exists to produce an actionable
message, not to replace Apple's.

Because the base never booted, each clone's first boot **is** "first boot after
restore," so `VZMacGuestProvisioningOptions` (five fields, validated at create
time via `validate()` — fail in 1 s, not after 20 min) provisions each VM's own
account. Per-VM user-data rides the existing virtio-fs `provision/` share; the
baked-in shim is VM-agnostic.

Deleted: the per-VM `installProvisionerDaemon` call and its root fail-fast in
`Create.swift` / `AppState`. The GUI "Root access" row moves to the base-build
moment. Existing macOS bundles: unsupported (pre-1.0, no migration).

### 3. Per-VM vmnet network — pinned IPs and native port publishing

Replaces `VZNATNetworkDeviceAttachment` for **both** guest OSes. Each VM gets
its own shared-mode network, built in the process that starts the VM (vmnet
networks are same-process-only):

```c
config = vmnet_network_configuration_create(VMNET_SHARED_MODE, &status);
vmnet_network_configuration_add_dhcp_reservation(config, &vmMAC, &reservedIP);
for rule in publications:
    vmnet_network_configuration_add_port_forwarding_rule(
        config, IPPROTO_TCP, AF_INET,
        rule.guestPort /*internal*/, rule.hostPort /*external*/, &reservedIP);
network = vmnet_network_create(config, &status);
attachment = VZVmnetNetworkDeviceAttachment(network: network)
```

All `macos(26.0)` (SDK-verified; nothing newer exists — the 26.5→27 SDK diff of
`vmnet.h` is empty). Works non-root with `com.apple.security.virtualization`
(empirically verified on this host; the same single entitlement Apple's
`container` network helper ships).

Subnet allocation is **explicit, not defaulted**: without
`vmnet_network_configuration_set_ipv4_subnet`, the framework picks its own /24
under 192.168/16 at network-create time (DocC,
`vmnet_network_configuration_create` defaults) — too late, because the DHCP
reservation must name an address *before* create and "the framework doesn't
allow modifying reservation while a network is active" (DocC,
`add_dhcp_reservation`). So the allocator assigns each VM a distinct /24 at
create time (recorded in bundle metadata, avoiding the system shared-NAT
subnet), calls `set_ipv4_subnet`, and reserves an address from the usable
range — the framework reserves the first, second (host), and last addresses of
any subnet.

Consequences:

- `spook ip` = metadata read. All lease-file parsing is deleted.
- Publications: templates contribute defaults (OpenClaw → `18789:18789`);
  users add `--publish <host>:<guest>` (repeatable) or the GUI field. Runner
  publishes nothing. Host-port conflicts fail at start with a typed error.
- Per-VM networks isolate VMs from each other (deliberate, good for CI).

**Probe gate (resolves before implementation proceeds):** vmnet forwarded
ports were unreachable from the host's own loopback on macOS 26 — Apple DTS
confirmed it as vmnet limitation FB7731708 (forums thread 822658); one
community report (Jun '26) says macOS 27 fixed it; the fix has no SDK trace and
is **absent from the current Beta 4 release notes**. Implementation step 1 is a
live probe: boot a VM with a rule, `curl http://localhost:<port>`. Pass → vmnet
rules are the single shipped mechanism. Fail → ship the reserved-IP relay
instead (`NWListener` on `127.0.0.1:<host>` dialing `<reservedIP>:<guest>` per
accepted connection — Apple `container`'s `--publish` pattern; deterministic
because the IP is reserved, no discovery). One mechanism ships either way.

### 4. vsock readiness — the guest says "done"; nobody polls

- Guest: `spook-signal`, a ~30-line binary (`socket(AF_VSOCK)` → connect to
  host → write exit status), injected into the base beside the shim. The shim's
  last line calls it with the user-data exit code. Linux cloud-init's final
  `runcmd` uses python's `AF_VSOCK` (present in cloud images).
- Host: the existing socket device (`VirtualMachineConfiguration.swift:179`)
  and port-9469 listener gain a `provisioningComplete(exitCode:)` frame in
  `AgentFrameCodec`. CLI `Start` adds the listener the GUI already has
  (`setSocketListener(_:forPort:)` +
  `listener(_:shouldAcceptNewConnection:fromSocketDevice:)`).
- Consumers: `spook start` prints the definitive provisioning outcome (exit
  code + pointer to logs on failure); GUI state transitions on the frame; a
  future `--wait` flag blocks pipelines until true readiness. No listener
  timeout is added — absence of the signal leaves the state "provisioning" and
  the logs/archive on the share remain the diagnostic path.

## Data flows

**First macOS create (base miss):** resolve IPSW → build base (progress UI;
one root/helper approval) → then the normal instant-create path below.

**Every macOS create:** ensure base (hit: instant) → bundle with overlay +
cloned aux + fresh identity + reserved IP + publications → write per-VM
`first-boot.sh` (template/user-data; token minting for runners unchanged,
late, System-keychain PAT) → done in seconds, no root.

**Start / first boot:** build vmnet network from metadata → build disk stack →
`VZMacGuestProvisioningOptions` (validated) on first start → guest boots:
native account creation → shim mounts share, runs `first-boot.sh` as root →
`spook-signal` fires → host announces readiness; published ports live.

**Scrub / reset (pool):** stop → delete overlay → new overlay + cloned aux +
fresh machine identifier. MAC, reserved IP, and publications are kept — the
network identity is the pool slot's, not the workload's. Base `layerUUID` is
unchanged by construction (framework writes only the topmost layer) — the
scrub-validation story the engineering packet asked for.

## Error handling

| Failure | Behavior |
|---|---|
| Base build interrupted | temp dir never renamed; next create rebuilds; lock prevents double-build |
| Base drift (layerUUID mismatch) | typed error naming the VM and base; suggest recreate VM or rebuild base |
| Concurrent base builds | second waits on `O_EXLOCK`, reports the winner's progress |
| Host port in use | typed error at start listing port and owner hint |
| Provisioning options invalid | `validate()` at create; VZError 40001–40003 mapped to actionable messages |
| Guest never signals | state stays "provisioning"; share logs + `first-boot.exit-code` remain the diagnostic; no synthetic timeout |
| Old-IPSW guest (< macOS 27) | fail at create: native provisioning requires 27-on-27 |

## Testing

- **Unit:** BaseImageStore (paths, locking, metadata, layerUUID logic — ASIF
  fixtures via `diskutil image create`, ~0.07 s each); PortPublication parsing
  (`--publish` forms, collisions); reservation allocator (respects reserved
  first/second/last addresses); DiskStack construction errors; readiness frame
  codec round-trip; overlay+aux clonefile create on APFS temp.
- **Live (gated, like existing live suites):** base build once; instant create
  asserts < 5 s; boot → readiness frame received → account exists → published
  port answers on `localhost` (the probe gate, kept as a permanent regression
  assertion for whichever mechanism ships); scrub → base `layerUUID` unchanged.
- **DocConsistency:** layer rules unchanged (DiskImageKit/vmnet usage confined
  to `SpooktacularInfrastructureApple`).
- `scripts/validate-linux-provisioning.sh` untouched; a macOS sibling script
  covers the new flow end-to-end.

## What each audience gets

| Capability | Evaluator (local Mac) | Cloud production (EC2 Mac root service) |
|---|---|---|
| Create #2..N | seconds, rootless, no prompts | warm-pool spin-up ≈ one overlay file per runner |
| Root surface | one approval, at base build only | none extra (already root) |
| OpenClaw | gateway on `localhost:18789` out of the box | gateway published on instance interfaces for fleet access |
| Runner | registers and reports online, zero extra steps | provable scrubs (base layerUUID) + per-VM isolation between jobs |
| `spook ip` | instant, exact | deterministic addressing for orchestration |
| Readiness | visible "done (exit 0)" moment | `--wait`-able creates; failures surface immediately with logs |
| Disk footprint | N VMs ≈ 1× base + deltas | same; ASIF transfers efficiently for future fleet distribution |

## Out of scope / future work

- **OCI registry distribution of bases** (`spook base push/pull`) — verified
  viable (Tart's media-type pattern; ECR accepts arbitrary artifact types);
  separate spec.
- **`LayerType.cache`** over slow storage (EBS-resident base + instance-store
  cache on EC2 M4) — roadmap note.
- **Save/restore warm pools** (`saveMachineStateTo`, host-tied key) — separate
  feature.
- **Host-only networks** (`VMNET_HOST_MODE`) and dynamic post-start rule
  management (`vmnet_interface_*_ip_port_forwarding_rule`).
- Linux ASIF migration; remote-desktop `logsInAutomatically` template polish.

## Sources

- DocC (re-verified via xcode MCP 2026-07-28):
  `/documentation/DiskImageKit` (Stacked Disk Images; Important details —
  one cache layer, layer ordering, UUID compatibility;
  `IncompatibleStackingError`), `/documentation/DiskImageKit/DiskImage`
  (stacking example, `VZDiskImageStorageDeviceAttachment` interop),
  `/documentation/DiskImageKit/DiskImage/layerUUID`,
  `/documentation/vmnet/vmnet_network_configuration_add_port_forwarding_rule(_:_:_:_:_:_:)`
  (param semantics, post-start rule note),
  `/documentation/vmnet/vmnet_network_configuration_set_ipv4_subnet(_:_:_:)`
  (reserved addresses).
- SDK (Xcode 27 beta, on-disk, 2026-07-24/28): DiskImageKit swiftinterface
  (`DiskImage`, `LayerType.overlay(blockCount:)`/`.cache`, `StackedImage`,
  `layerUUID`/`parentUUID`); Virtualization swiftinterface line 74
  (`init(diskImage:cachingMode:synchronizationMode:)`); `vmnet.h`
  (26.0 family; 26.5→27 diff empty); `VZMacGuestProvisioningOptions.h`
  (five properties); `VZVirtioSocketListener.h` / `VZVirtioSocketDevice.h`.
- macOS 27 Beta 4 release notes: DiskImageKit entry (177868758); network
  security TLS 1.2 note (176055825, scoped to MDM/update system processes —
  not our surfaces). Loopback-fix entry **absent** (hence the probe gate).
- Apple Developer Forums thread 822658 (DTS: FB7731708 vmnet loopback
  limitation; community fix confirmation on 27). TN3165 (pf is not API).
- Empirical (this macOS 27.0 host): vmnet config/create non-root with
  `com.apple.security.virtualization`; ASIF creation 0.066 s / 4 MB for 2 GiB;
  APFS clonefile instant.
