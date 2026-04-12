# Remote Desktop Access

Connect to Spooktacular VMs via VNC for remote development, QA testing, and design review.

## Overview

Spooktacular VMs include full macOS display output backed by a
virtual GPU (`VZMacGraphicsDeviceConfiguration`). Combined with
macOS's built-in Screen Sharing (VNC) server, this enables remote
graphical access to any VM from anywhere on your network.

### Use Cases

- **Remote development** — Full macOS desktop for Xcode, Interface
  Builder, and Simulator from any machine
- **QA testing** — Manual testing of macOS and iOS apps in a
  controlled, reproducible VM environment
- **Design review** — Share a running app with designers and
  stakeholders without giving them SSH access
- **Training and demos** — Provide ephemeral macOS desktops for
  workshops or customer demos
- **Help desk** — Remote access to user-like macOS environments
  for support and troubleshooting

## Enabling Screen Sharing via Provisioning

The most reliable way to enable VNC access is through a provisioning
script that runs automatically when the VM boots.

### Using disk-inject (Zero-Touch)

```bash
spook create desktop-vm --from-ipsw latest \
    --cpu 4 --memory 8 --disk 64 \
    --displays 1 \
    --user-data ~/enable-screensharing.sh \
    --provision disk-inject
```

Where `enable-screensharing.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Enable Screen Sharing (VNC server)
sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist

# Set the VNC password (for VNC-only clients)
sudo defaults write /Library/Preferences/com.apple.RemoteManagement VNCAlwaysStartOnConsole -bool true

# Enable Remote Management for full control
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate \
    -configure -access -on \
    -configure -allowAccessFor -allUsers \
    -configure -restart -agent -privs -all

echo "Screen Sharing enabled"
```

### Using the Kubernetes CRD

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: remote-desktop
  namespace: desktops
spec:
  image: ghcr.io/spooktacular/macos:15.4
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  displays: 1
  network:
    mode: bridged
    interface: en0
  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
      sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
          -activate -configure -access -on \
          -configure -allowAccessFor -allUsers \
          -configure -restart -agent -privs -all
```

See <doc:Provisioning> for details on all four ``ProvisioningMode``
strategies.

## Connecting via VNC

### macOS Screen Sharing App (Built-in)

The simplest way to connect from another Mac:

1. Find the VM's IP address:

```bash
spook ip desktop-vm
# 192.168.64.3
```

2. Open Screen Sharing (Cmd+K in Finder, or open the Screen Sharing
   app directly):

```bash
open vnc://192.168.64.3
```

3. Authenticate with the guest macOS user credentials.

### From Any VNC Client

Use any VNC client (RealVNC, TigerVNC, etc.) to connect:

- **Server:** The VM's IP address (from `spook ip`)
- **Port:** 5900 (default VNC port)
- **Authentication:** macOS user credentials or VNC password

```bash
# Using a command-line VNC client
vncviewer 192.168.64.3:5900

# Or with SSH tunnel (see Security section)
ssh -L 5900:192.168.64.3:5900 ec2-user@bastion
vncviewer localhost:5900
```

### Network Mode Considerations

The ``NetworkMode`` you choose affects how you connect:

| Network Mode | VM IP reachable from | Connection method |
|-------------|---------------------|-------------------|
| ``NetworkMode/nat`` | Host only | Connect from host, or SSH tunnel |
| ``NetworkMode/bridged(interface:)`` | Entire LAN | Direct VNC connection |
| ``NetworkMode/hostOnly`` | Host and other VMs | Connect from host, or SSH tunnel |
| ``NetworkMode/isolated`` | Nowhere | Not suitable for VNC |

For remote desktop scenarios, **bridged** mode is recommended because
it gives the VM its own IP address on the LAN, allowing direct
connections from any machine.

> Note: Bridged networking requires the `com.apple.vm.networking`
> entitlement. See ``NetworkMode`` for the entitlement details.

## Display Configuration

### Resolution and DPI

By default, each virtual display is configured at
**1920 x 1200 @ 80 PPI**. This is set by ``VMConfiguration`` when
applying the ``VMSpec``:

```swift
VZMacGraphicsDisplayConfiguration(
    widthInPixels: 1920,
    heightInPixels: 1200,
    pixelsPerInch: 80
)
```

### Dual Monitors

Configure two virtual displays for workflows that benefit from
extra screen space:

```bash
# Create a VM with 2 displays
spook create design-vm --cpu 4 --memory 8 --displays 2

# Or update an existing VM
spook set design-vm --displays 2
```

Each display gets its own VNC session. Connect to the second
display on port 5901.

The ``VMSpec/displayCount`` property controls the number of
displays (valid range: 1-2).

### Auto-Resize Display

When ``VMSpec/autoResizeDisplay`` is `true` (the default), the
guest display resolution adjusts to match the Spooktacular window
size on the host. This is useful when viewing the VM display
locally:

```bash
# Enable auto-resize (default)
spook set my-vm --enable-auto-resize

# Disable for a fixed resolution
spook set my-vm --disable-auto-resize
```

> Note: Auto-resize affects the local Spooktacular display window.
> VNC clients negotiate their own display size with the Screen
> Sharing server.

## Performance Considerations

### LAN vs WAN

| Factor | LAN (< 1ms latency) | WAN (50-200ms latency) |
|--------|---------------------|----------------------|
| Resolution | Full 1920x1200 | Consider 1280x800 |
| Color depth | 32-bit | 16-bit for better performance |
| Frame rate | 30-60 fps | 15-30 fps |
| Responsiveness | Excellent | Usable for most tasks |

### Bandwidth Requirements

Approximate bandwidth for VNC at different quality levels:

| Resolution | Quality | Bandwidth |
|-----------|---------|-----------|
| 1280x800 | Low (16-bit) | 2-5 Mbps |
| 1920x1200 | Medium | 5-15 Mbps |
| 1920x1200 | High (32-bit) | 15-30 Mbps |
| 3840x2400 | High (Retina) | 40-80 Mbps |

### Optimizing for Slow Connections

For WAN or high-latency connections:

1. Use a lower resolution display
2. Reduce color depth in your VNC client settings
3. Enable compression (most clients support ZRLE or Tight encoding)
4. Consider an SSH tunnel with compression (`ssh -C`)

```bash
# SSH tunnel with compression for slow links
ssh -C -L 5900:192.168.64.3:5900 user@bastion
```

## Future: High-Performance Streaming

Spooktacular's roadmap includes high-performance display streaming
using hardware video encoding:

- **4K @ 60fps** — HEVC (H.265) encoding via VideoToolbox on the
  host's hardware encoder
- **Sub-frame latency** — Direct Metal capture to hardware encoder
  pipeline
- **Adaptive bitrate** — Automatic quality adjustment based on
  network conditions
- **WebRTC transport** — Browser-based access without a VNC client

Until then, the macOS built-in Screen Sharing (VNC) server provides
reliable access for most use cases.

## Audio Forwarding

Spooktacular VMs include a virtual audio device
(`VZVirtioSoundDeviceConfiguration`) by default. Audio from the guest
macOS is forwarded to the host's speakers.

### Enabling Audio

Audio is enabled by default in ``VMSpec``. To explicitly control it:

```bash
# Audio enabled (default)
spook create my-vm --enable-audio

# Audio disabled (saves resources for headless CI)
spook create my-vm --disable-audio

# Enable microphone passthrough (for voice/video calls in the VM)
spook create my-vm --enable-microphone
```

See ``VMSpec/audioEnabled`` and ``VMSpec/microphoneEnabled`` for the
API details.

### Audio over VNC

Standard VNC does not support audio. For remote audio:

1. Use Apple Remote Desktop (ARD) which supports audio forwarding
2. Use a third-party solution like PulseAudio over network
3. For simple cases, forward audio via the Spooktacular host's
   speakers (if you are physically near the host)

## Clipboard Sharing

Spooktacular supports bidirectional clipboard sharing between the
host and guest macOS. Copy text or images on the host, paste in
the VM, and vice versa.

### Configuration

Clipboard sharing is enabled by default via
``VMSpec/clipboardSharingEnabled``:

```bash
# Clipboard sharing on (default)
spook create my-vm

# Clipboard sharing off (for security-sensitive VMs)
spook create secure-vm --disable-clipboard
```

### How It Works

The Virtualization framework's `Spice` channel handles clipboard
synchronization transparently. Both the local Spooktacular display
window and VNC sessions benefit from this feature.

> Note: Clipboard sharing works between the host and guest. If you
> are connecting via VNC from a third machine, clipboard operations
> go: your machine -> VNC -> guest -> Virtualization -> host.

## Security

### VNC over SSH Tunnel

Never expose VNC (port 5900) directly to the internet. Always use
an SSH tunnel:

```bash
# From your local machine, through a bastion host
ssh -L 5900:192.168.64.3:5900 ec2-user@bastion-host

# Then connect your VNC client to localhost:5900
open vnc://localhost
```

### VPC-Only Access

On EC2 Mac deployments, restrict VNC access to the VPC:

```bash
# Security group rule: allow VNC only from the VPN CIDR
aws ec2 authorize-security-group-ingress \
    --group-id sg-0xxxx \
    --protocol tcp \
    --port 5900 \
    --cidr 10.0.0.0/8
```

### Per-VM Authentication

Each VM has its own macOS user accounts and passwords. You can
create dedicated accounts for different users:

```bash
# Inside the VM, create a read-only viewer account
sudo dscl . -create /Users/viewer
sudo dscl . -create /Users/viewer UserShell /bin/bash
sudo dscl . -create /Users/viewer RealName "Viewer"
sudo dscl . -passwd /Users/viewer "viewer-password"
sudo dscl . -create /Users/viewer UniqueID 502
sudo dscl . -create /Users/viewer PrimaryGroupID 20
sudo createhomedir -c -u viewer
```

### Isolated Desktops

For maximum security, use ``NetworkMode/hostOnly`` networking and
connect only from the host:

> Important: Host-only networking currently falls back to NAT mode.
> VMs will have internet access until a future release adds true
> host-only isolation. Plan your network security accordingly.

```bash
spook create secure-desktop \
    --cpu 4 --memory 8 --disk 64 \
    --network host-only \
    --disable-audio

# Connect only from the host machine
open vnc://$(spook ip secure-desktop)
```

## Multiple Users Accessing Different VMs

Each VM runs independently with its own display, network identity,
and user accounts. This enables multi-user scenarios:

### Shared Development Environment

```bash
# Create one VM per developer
spook create dev-alice --cpu 4 --memory 8 --disk 64 --network bridged:en0
spook create dev-bob --cpu 4 --memory 8 --disk 64 --network bridged:en0

# Each developer connects to their own VM via VNC
# Alice: open vnc://192.168.1.101
# Bob:   open vnc://192.168.1.102
```

### QA Test Lab

```bash
# Create VMs for testing (clone from pre-configured bases)
spook clone base-sonoma qa-sonoma
spook set qa-sonoma --network bridged:en0

spook clone base-sequoia qa-sequoia
spook set qa-sequoia --network bridged:en0

# QA team members connect to whichever version they need
```

### Kubernetes-Managed Desktops

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: desktop-alice
  namespace: desktops
  labels:
    user: alice
spec:
  image: ghcr.io/spooktacular/macos:15.4
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  displays: 1
  network:
    mode: bridged
    interface: en0
  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
---
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: desktop-bob
  namespace: desktops
  labels:
    user: bob
spec:
  image: ghcr.io/spooktacular/macos:15.4
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  displays: 1
  network:
    mode: bridged
    interface: en0
  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
```

```bash
# Find each user's VM IP
kubectl get macosvm -n desktops -o wide

# NAMESPACE  NAME           IP              NODE         STATUS
# desktops   desktop-alice  192.168.1.101   mac-host-01  Running
# desktops   desktop-bob    192.168.1.102   mac-host-01  Running
```

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:Provisioning>
- <doc:EC2MacDeployment>
- <doc:KubernetesGuide>
- <doc:CLIReference>

### Key Types

- ``VMSpec``
- ``VMConfiguration``
- ``NetworkMode``
