# Spooktacular Design Specification

**Date:** 2026-04-11
**Status:** Draft
**Authors:** Principal Engineer + Claude

---

## Context

macOS virtualization on Apple Silicon is powerful but fragmented. Existing tools are either CLI-only (Tart), GUI-only (VirtualBuddy), or general-purpose (UTM). None provide a unified CLI+GUI experience with built-in MDM, OCI distribution, AND Kubernetes-native fleet management — all in Swift, all in one product.

**Spooktacular** fills this gap: a lightweight macOS app that runs macOS VMs with enterprise-grade management capabilities while remaining simple enough for any developer to spin up a VM in one command.

### Problem statement

Enterprises need macOS VMs as CI runners (GitHub Actions, Buildkite, etc.) and want to manage them like Kubernetes resources. Individual developers want to test across macOS versions without complexity. Today, achieving either requires stitching together multiple tools, custom scripts, and significant operational overhead.

### Hard constraints (Apple-imposed)

- **2-VM per host kernel limit** — `hv_apple_isa_vm_quota=2` in XNU, not just EULA. Cannot be worked around in production.
- **Apple Silicon only** — `Virtualization.framework` macOS guest support is ARM-only.
- **Guest ≤ Host version** — Cannot run a newer macOS guest than the host.
- **No ACPI graceful shutdown** — `VZVirtualMachine.requestStop()` does not cleanly shut down macOS guests.
- **EULA: no service-bureau use** — Cannot sell VM compute to third parties. Internal enterprise use is permitted.

---

## Architecture Overview

**Guiding principle:** Apple's APIs are well-documented. Our code is a thin, clean layer on top — not a reimagination. No protocol abstractions with single conformances. No hacks. Direct use of Virtualization.framework, exactly as Apple's sample code demonstrates.

### Process model: Helper daemon + thin clients

```
Spooktacular.app/
├── Contents/MacOS/
│   ├── Spooktacular            ← SwiftUI GUI (thin HTTP client)
│   └── spook                   ← CLI (thin HTTP client)
├── Contents/Library/LaunchAgents/
│   └── com.spooktacular.helper.plist
└── Contents/Helpers/
    └── SpooktacularHelper      ← long-lived LaunchAgent
                                   owns VMs, MDM server, control API
```

**SpooktacularHelper** (registered via `SMAppService.agent`) is the single owner of all VM instances, the embedded MDM server, and the HTTP control API. The GUI and CLI are pure HTTP clients.

External orchestrators (Kubernetes operator, GitHub Actions, shell scripts) drive the same HTTP API.

### Project structure (flat, direct)

```
Spooktacular/
├── SpooktacularKit/           ← core library, directly uses Virtualization.framework
│   ├── VirtualMachine.swift        wraps VZVirtualMachine
│   ├── VMConfiguration.swift       builds VZVirtualMachineConfiguration
│   ├── VMBundle.swift              bundle directory (config.json + artifacts)
│   ├── RestoreImageManager.swift   VZMacOSRestoreImage + VZMacOSInstaller
│   ├── CloneManager.swift          APFS clonefile + new VZMacMachineIdentifier
│   ├── NetworkConfiguration.swift  NAT / bridged / isolated / host-only
│   ├── SharedFolders.swift         VZVirtioFileSystemDeviceConfiguration
│   ├── SnapshotManager.swift       saveMachineStateTo / restoreMachineStateFrom
│   └── VsockConnection.swift       VZVirtioSocketDevice host↔guest channel
│
├── SpooktacularMDM/           ← embedded Swift MDM server
│   ├── MDMServer.swift             HTTP check-in + command handler
│   ├── MDMCommands.swift           plist command builders
│   ├── CertificateManager.swift    self-signed CA + device certs
│   └── EnrollmentProfile.swift     .mobileconfig builder
│
├── SpooktacularOCI/           ← OCI distribution
│   ├── OCIClient.swift             OCI Distribution Spec HTTP client
│   ├── OCIManifest.swift           manifest + layer construction
│   └── OCILayerBuilder.swift       chunked content-addressed disk layers
│
├── SpooktacularAPI/           ← HTTP control API
│   ├── APIServer.swift             NWListener HTTP server
│   ├── APIRoutes.swift             route handlers → SpooktacularKit
│   └── APITypes.swift              Codable request/response DTOs
│
├── SpooktacularHelper/        ← LaunchAgent daemon
│   └── main.swift
│
├── Spooktacular/              ← SwiftUI GUI (thin client)
│   └── ...views...
│
├── spook/                     ← CLI (thin client, swift-argument-parser)
│   └── ...commands...
│
├── SpooktacularOperator/      ← K8s operator (Swift, cross-compiled to Linux)
│   ├── K8sClient.swift
│   ├── MacOSVMController.swift
│   └── Scheduler.swift
│
└── GuestTools/                ← tiny vsock daemon installed in guest
    └── SpooktacularGuest.swift     ~30 lines: MDM wake-up + graceful shutdown
```

**No protocol layers with single conformances.** SpooktacularKit uses VZVirtualMachine directly. The API server calls SpooktacularKit directly. GUI and CLI are thin HTTP clients.

---

## VM Bundle Format

```
~/.spooktacular/vms/my-vm.vm/
├── config.json              # VMSpec: cpu, memory, disks, networks, displays
├── hardware_model.bin       # VZMacHardwareModel.dataRepresentation
├── machine_identifier.bin   # VZMacMachineIdentifier.dataRepresentation
├── aux.bin                  # VZMacAuxiliaryStorage
├── disk.img                 # APFS sparse disk image
├── metadata.json            # UUID, created, lastBoot, installedVersion, state
└── SavedStates/             # optional
    └── snapshot-001.vzvmsave
```

For OCI distribution, bundles are split into layers:
- Config layer: `config.json` + `hardware_model.bin` + `machine_identifier.bin`
- Disk layer: chunked, resumable (content-addressed chunks, Tart v2 model)
- Aux/NVRAM layer: separate blob
- SavedStates: excluded from distribution (host-specific)

---

## Control API

HTTP server on configurable interface. Default: `127.0.0.1:9470`. For K8s fleet: `0.0.0.0:9470`.

Authentication: bearer token, generated on first run, stored at `~/.spooktacular/api-token`.

### Endpoints

**Health & info:**
- `GET /v1/health` → `{ version, vmCount, maxVMs: 2, uptime }`

**IPSW management:**
- `GET /v1/restore-images` → list cached IPSWs + latest available
- `POST /v1/restore-images/fetch` → download latest IPSW (progress via SSE)

**VM lifecycle:**
- `GET /v1/vms` → list all VMs with state
- `POST /v1/vms` → create VM `{ name, source: { ipsw | clone | oci }, spec: { cpu, memory, disk, networks, sharedFolders } }`
- `GET /v1/vms/{name}` → VM details + state + IP
- `POST /v1/vms/{name}/start` → `{ headless, userData, provisioningMode, mdm, ssh }`
- `POST /v1/vms/{name}/stop` → `{ graceful: bool, timeout }`
- `POST /v1/vms/{name}/clone` → `{ newName }` (APFS clonefile, new MachineIdentifier)
- `DELETE /v1/vms/{name}`
- `GET /v1/vms/{name}/ip` → resolved IP address
- `POST /v1/vms/{name}/snapshot` → save state (macOS 14+)
- `POST /v1/vms/{name}/restore` → restore state

**Provisioning & management (MDM-backed):**
- `POST /v1/vms/{name}/exec` → `{ command, timeout }` (via MDM InstallEnterpriseApplication or SSH)
- `POST /v1/vms/{name}/push` → push file to guest (via .pkg or shared folder)
- `GET /v1/vms/{name}/inventory` → device info via MDM DeviceInformation
- `POST /v1/vms/{name}/mdm/install-profile` → push .mobileconfig
- `POST /v1/vms/{name}/mdm/remove-profile` → remove profile

**OCI registry:**
- `POST /v1/vms/{name}/push-image` → `{ registry, tag }` push to OCI registry
- `POST /v1/vms/pull-image` → `{ registry, tag, name }` pull from OCI registry

**Events (Server-Sent Events):**
- `GET /v1/events` → stream of state changes, provisioning progress, logs

---

## Provisioning Model (No Hacks — Apple-Documented Patterns Only)

### One-time base image setup (standard macOS administration)

```
spook create base --from-ipsw latest
spook start base
# 1. User walks through Setup Assistant (Apple's intended first-boot flow)
# 2. In Spooktacular GUI: click "Enroll VM in Spooktacular MDM"
#    → App generates .mobileconfig enrollment profile
#    → Delivers to guest via shared folder (VirtIO — Apple-documented)
#    → User installs profile in guest: System Settings → Profiles → Install
# 3. MDM enrollment triggers → MDM pushes GuestTools.pkg
#    via InstallEnterpriseApplication (Apple MDM spec)
#    → macOS installs vsock daemon automatically
# 4. Base is now: macOS + MDM enrolled + vsock daemon
spook stop base
```

All steps use Apple-documented mechanisms. No disk injection, no filesystem hacks.

### Per-job provisioning (fully automated, zero SSH)

```
spook clone base runner-01
spook start runner-01 --headless --user-data ./setup.sh

1. APFS clonefile (instant) + new VZMacMachineIdentifier
2. Clone boots → reads cloned enrollment profile → checks in with our MDM
3. Our MDM registers new device (new UDID from new MachineIdentifier)
4. MDM queues: InstallEnterpriseApplication (provision.pkg wrapping setup.sh)
5. Vsock daemon triggers: profiles renew -type enrollment
6. MDM client polls → receives command → installs .pkg → postinstall = setup.sh
7. Output streamed back via vsock to control API
```

User-data scripts run via MDM's InstallEnterpriseApplication — not SSH.

### Two provisioning modes

| Mode | How it works | Requires |
|---|---|---|
| `mdm` (default) | Clone has MDM enrollment from base → MDM pushes .pkg with user-data | Base image with MDM enrollment + vsock daemon |
| `ssh` (fallback) | Wait for IP → SSH in → execute script | SSH enabled in base image |

### BYO MDM

```
spook clone base runner-01 --mdm external
```

When `--mdm external`:
- Our built-in MDM is not used for provisioning
- The base image has the customer's corporate MDM enrollment instead
- Their MDM handles script delivery and ongoing management
- User-data delivery is through their MDM's mechanisms

```
spook start runner-01 --mdm internal    # our MDM (default)
spook start runner-01 --mdm external    # customer's corporate MDM
spook start runner-01 --mdm none        # no MDM, use SSH fallback
```

---

## Embedded Swift MDM Server

~1,500 lines of Swift, running inside the helper daemon. No APNs (vsock wake-up instead), no SCEP (pre-generated certs). Implements Apple's documented MDM protocol.

### Components

| File | Purpose |
|---|---|
| `MDMServer.swift` | HTTP check-in handler (Authenticate, TokenUpdate, CheckOut) + command endpoint |
| `MDMCommands.swift` | Plist command builders for all supported commands |
| `CertificateManager.swift` | Self-signed CA generation (Security.framework), device cert generation |
| `EnrollmentProfile.swift` | .mobileconfig builder with MDM + Identity payloads |

### Supported MDM commands

- `InstallEnterpriseApplication` — push .pkg (user-data delivery)
- `InstallProfile` / `RemoveProfile` — configuration profiles
- `DeviceInformation` — OS version, serial, storage, hostname
- `EnableRemoteDesktop` — enable ARD/VNC
- `ShutDownDevice` / `RestartDevice` — lifecycle
- `EraseDevice` — factory reset
- `ScheduleOSUpdate` — macOS updates
- `SecurityInfo` — FileVault, firewall state

### Wake-up mechanism

No APNs. A tiny vsock daemon (~30 lines of Swift), installed in the base image via MDM's `InstallEnterpriseApplication` (as GuestTools.pkg):
1. Listens on vsock port 52
2. On receiving "checkin" signal: runs `profiles renew -type enrollment`
3. On receiving "shutdown" signal: runs `shutdown -h now`
4. On receiving "ping": responds with IP addresses

The helper sends vsock signals when MDM commands are queued. The guest's MDM client checks in instantly. No APNs infrastructure, no internet dependency for command delivery.

The helper sends vsock signals when commands are queued. MDM client checks in instantly.

---

## Networking Postures

| Posture | VZ Attachment | Entitlement | In MAS? |
|---|---|---|---|
| `nat` (default) | VZNATNetworkDeviceAttachment | None | Yes |
| `bridged` | VZBridgedNetworkDeviceAttachment | com.apple.vm.networking | Dev ID only |
| `isolated` | No NIC attached | None | Yes |
| `host-only` | VZFileHandleNetworkDeviceAttachment + virtual switch | None | Yes |

### Host-only implementation

Uses `VZFileHandleNetworkDeviceAttachment` with a user-space virtual switch:
- Helper creates a pair of file descriptors per VM
- Routes traffic between VMs and to the host
- Blocks internet-bound traffic (no default route)
- VMs can communicate with each other and the host via the virtual switch

### CLI surface

```
spook create my-vm --net nat                    # default
spook create my-vm --net bridged:en0            # bridged to interface
spook create my-vm --net isolated               # no network
spook create my-vm --net host-only              # VM↔VM + VM↔host only
spook create my-vm --net nat --net host-only    # multiple NICs
```

---

## OCI Distribution

Push/pull VM images to any OCI-compliant container registry.

### Image format (Tart-compatible where possible)

```
Manifest:
  Config layer:    config.json + hardware_model.bin + machine_identifier.bin
  Disk layers:     chunked (64MB chunks, content-addressed, resumable)
  Aux layer:       aux.bin
  Media types:     application/vnd.spooktacular.config.v1
                   application/vnd.spooktacular.disk.v2
                   application/vnd.spooktacular.aux.v1
```

### Commands

```
spook push my-vm ghcr.io/myorg/macos-runner:15.4
spook pull ghcr.io/myorg/macos-runner:15.4 my-vm
spook images    # list cached OCI images
```

### Content-addressed IPSW cache

IPSWs are cached at `~/.spooktacular/cache/ipsw/` by SHA256. Multiple VMs created from the same IPSW share the cached download.

---

## Snapshot / Save-Restore

Requires macOS 14+ (Sonoma) on both host and guest.

```
spook snapshot my-vm checkpoint-1
spook restore my-vm checkpoint-1
spook snapshots my-vm    # list snapshots
```

Snapshots saved to `SavedStates/` inside the VM bundle. State file size ≈ VM RAM.

---

## Shared Folders

```
spook create my-vm --share ~/Projects:projects:rw
spook create my-vm --share ~/Data:data:ro
```

Uses `VZVirtioFileSystemDeviceConfiguration` with `macOSGuestAutomountTag`. Folders appear under `/Volumes/My Shared Files/` in the guest.

---

## Kubernetes Integration

**Written entirely in Swift** using SwiftNIO and a custom K8s client.

### Custom Resource Definition

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ci-runner-01
  namespace: ci
spec:
  image: ghcr.io/myorg/macos-runner:15.4
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  network:
    mode: nat
  provisioning:
    mode: mdm
    userData: |
      #!/bin/bash
      # setup CI runner
  mdm:
    mode: internal          # or: external, none
    externalURL: ""         # if mode=external
  sharedFolders:
    - hostPath: /shared/artifacts
      guestTag: artifacts
      readOnly: false
  node: ""                  # optional: pin to specific Mac
status:
  phase: Running            # Pending, Creating, Installing, Provisioning, Running, Stopped, Failed
  ip: 192.168.64.3
  node: mac-mini-01
  mdmEnrolled: true
  snapshot: ""
  conditions:
    - type: Ready
      status: "True"
```

### Operator architecture (Swift)

```
┌─ Kubernetes cluster ─────────────────────────────────────┐
│                                                           │
│  spooktacular-operator (Swift binary, runs in pod)       │
│  ├── K8s client (SwiftNIO + K8s API via HTTPS)           │
│  ├── CRD watcher: MacOSVM resources                      │
│  ├── Node registry: known Mac hosts + capacity           │
│  ├── Scheduler: place VMs on Macs (capacity, affinity)   │
│  └── Reconciler: desired state → Spooktacular HTTP API   │
│                                                           │
└──────────────────┬────────────────────────────────────────┘
                   │ HTTP + bearer token
     ┌─────────────┼─────────────────────────┐
     │             │                         │
  Mac mini 1    Mac mini 2    ...    Mac mini N
  (≤2 VMs)      (≤2 VMs)             (≤2 VMs)
```

**The operator is a Swift binary** compiled for Linux (runs in a K8s pod) that:
1. Watches MacOSVM custom resources via the K8s API
2. Maintains a registry of Mac hosts (configured via a Secret or ConfigMap)
3. Schedules VMs onto Macs respecting the 2-VM kernel limit
4. Reconciles by calling each Mac's Spooktacular HTTP control API
5. Updates MacOSVM status with phase, IP, conditions

### Scheduling

- **Capacity-aware:** Each Mac can host ≤2 VMs (kernel limit)
- **Round-robin** by default across available Macs
- **Node pinning:** `spec.node: mac-mini-01` pins to specific Mac
- **Affinity/anti-affinity:** via standard K8s labels on MacOSVM resources

### Installation

```bash
# Install CRD
kubectl apply -f https://spooktacular.dev/k8s/crds/macosvm.yaml

# Install operator (Helm)
helm install spooktacular-operator spooktacular/operator \
  --set nodes[0].host=192.168.1.100 \
  --set nodes[0].token=<api-token> \
  --set nodes[1].host=192.168.1.101 \
  --set nodes[1].token=<api-token>

# Create a VM
kubectl apply -f vm.yaml
```

---

## SwiftUI GUI

### Screens

1. **VM List** — sidebar with VMs, status badges, quick actions (start/stop/delete)
2. **VM Display** — live `VZVirtualMachineView` for running VMs
3. **Create VM** — wizard: source (IPSW/OCI/clone) → spec (CPU/RAM/disk) → network → provisioning → create
4. **VM Detail** — configuration, snapshots, shared folders, MDM status, logs
5. **Settings** — API bind address, default specs, OCI registries, Mac fleet nodes
6. **IPSW Manager** — download/cache IPSW images

### Design principles

- SwiftUI throughout (macOS 14+ deployment target)
- Thin client: all state comes from the helper via VMControlClient
- Real-time updates via SSE event stream
- Native macOS look and feel (sidebar navigation, sheets, toolbars)

---

## CLI Command Set

```
spook create <name> [--from-ipsw <url|latest>] [--clone-from <name>] [--pull <oci-ref>]
                    [--cpu <n>] [--memory <size>] [--disk <size>]
                    [--net <posture>]... [--share <host:tag:mode>]...
                    [--headless]

spook start <name>  [--headless] [--user-data <path>] [--provision-via <mdm|ssh>]
                    [--mdm <internal|external|none>]
                    [--ssh-user <user>] [--ssh-key <path>]
spook stop <name>   [--graceful] [--timeout <seconds>]
spook delete <name> [--force]
spook list          [--format json|table]
spook ip <name>
spook exec <name> -- <command>...

spook clone <source> <target>
spook snapshot <name> <snapshot-name>
spook restore <name> <snapshot-name>
spook snapshots <name>

spook push <name> <oci-ref>
spook pull <oci-ref> <name>
spook images

spook set <name> [--cpu <n>] [--memory <size>] [--disk <size>]
spook get <name>

spook mdm status <name>
spook mdm install-profile <name> <path>
spook mdm device-info <name>

spook config [--bind <addr:port>] [--api-token <token>]
```

---

## Distribution

### Mac App Store

- App Sandbox with `com.apple.security.virtualization`, `com.apple.security.network.server`
- Container storage at `~/Library/Containers/<bundle>/Data/`
- Security-scoped bookmarks for user-selected IPSW files
- No bridged networking (restricted entitlement)
- Helper registered via SMAppService.agent

### Homebrew Cask

```ruby
cask "spooktacular" do
  app "Spooktacular.app"
  binary "#{appdir}/Spooktacular.app/Contents/MacOS/spook", target: "spook"
end
```

- Developer ID signed + notarized
- Full entitlements including `com.apple.vm.networking` (if approved)
- CLI symlinked to `/opt/homebrew/bin/spook`

### Dual build

Same Xcode project, two schemes:
- `Spooktacular-MAS` → MAS entitlements (no bridged network)
- `Spooktacular-DevID` → Developer ID entitlements (full feature set)

---

## Verification Plan

### Unit tests
- VMSpec serialization round-trip
- VMState transition validation
- MDM plist command generation
- OCI manifest/layer construction
- APFS clone with MachineIdentifier regeneration
- Control API request/response parsing

### Integration tests
- Full lifecycle: create-from-IPSW → start → wait-for-IP → exec → stop → delete
- Clone: create base → clone → verify new MachineIdentifier → boot clone
- MDM provisioning: create with user-data → verify script executed
- OCI: push to local registry → pull on clean system → boot
- Snapshot: create → boot → snapshot → modify → restore → verify state
- Shared folders: create with share → boot → verify mount in guest

### K8s integration tests
- Deploy operator → apply MacOSVM CRD → verify VM created on Mac
- Scale: apply 4 VMs across 2 Macs → verify scheduling (2 per Mac)
- Delete: delete MacOSVM → verify VM destroyed
- Status: verify phase transitions and IP reporting

### Manual verification
- GUI: create VM via wizard, view live display, manage snapshots
- MAS build: install from TestFlight, verify sandbox behavior
- Homebrew: `brew install --cask spooktacular`, verify CLI symlink

---

## Implementation Order

1. **Core VM lifecycle** — SpooktacularKit (VirtualMachine, VMBundle, RestoreImageManager, CloneManager)
2. **Helper daemon + control API** — SpooktacularHelper + SpooktacularAPI
3. **CLI** — spook binary with swift-argument-parser
4. **Networking postures** — NAT, bridged, isolated, host-only
5. **Shared folders + snapshots** — VirtIO file system, save/restore state
6. **Embedded MDM server** — SpooktacularMDM: check-in, commands, enrollment
7. **Guest tools + provisioning chain** — vsock daemon, MDM-based user-data delivery
8. **OCI distribution** — SpooktacularOCI: push/pull to container registries
9. **SwiftUI GUI** — all screens (can be developed in parallel from step 3)
10. **Kubernetes operator** — CRD, controller, Helm chart (all Swift)
11. **BYO MDM support** — external MDM enrollment
12. **MAS + Homebrew packaging** — dual build, signing, notarization
13. **Testing + hardening** — full test suite across all features
