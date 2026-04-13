# Spooktacular Kubernetes Integration

Manage macOS virtual machines on Apple Silicon nodes using standard Kubernetes
workflows. Define VMs as custom resources, apply them with `kubectl`, and let
the Spooktacular controller handle provisioning, lifecycle, and cleanup.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                             │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    Linux Node(s)                              │  │
│  │                                                               │  │
│  │  ┌─────────────────────────────────┐                          │  │
│  │  │  Spooktacular Controller Pod    │                          │  │
│  │  │                                 │                          │  │
│  │  │  - Watches MacOSVM CRDs         │                          │  │
│  │  │  - Schedules VMs to Mac nodes   │                          │  │
│  │  │  - Updates status subresources  │                          │  │
│  │  │  - Manages VM lifecycle         │                          │  │
│  │  └──────────┬──────────────────────┘                          │  │
│  │             │ HTTP API calls                                   │  │
│  └─────────────┼─────────────────────────────────────────────────┘  │
│                │                                                     │
│  ┌─────────────┼─────────────────────────────────────────────────┐  │
│  │             ▼         Mac Nodes (Apple Silicon)               │  │
│  │                                                               │  │
│  │  ┌──────────────────┐  ┌──────────────────┐                  │  │
│  │  │  mac-mini-01     │  │  mac-studio-01   │  ...             │  │
│  │  │                  │  │                  │                  │  │
│  │  │  spook serve     │  │  spook serve     │                  │  │
│  │  │  :8484           │  │  :8484           │                  │  │
│  │  │                  │  │                  │                  │  │
│  │  │  ┌────────────┐  │  │  ┌────────────┐  │                  │  │
│  │  │  │ macOS VM 1 │  │  │  │ macOS VM 3 │  │                  │  │
│  │  │  └────────────┘  │  │  └────────────┘  │                  │  │
│  │  │  ┌────────────┐  │  │  ┌────────────┐  │                  │  │
│  │  │  │ macOS VM 2 │  │  │  │ macOS VM 4 │  │                  │  │
│  │  │  └────────────┘  │  │  └────────────┘  │                  │  │
│  │  └──────────────────┘  └──────────────────┘                  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                    K8s API Server                             │  │
│  │                                                               │  │
│  │  MacOSVM CRD ──► kubectl get mvm                             │  │
│  │  NAME              PHASE    IP             NODE     AGE       │  │
│  │  ci-runner-macos   Running  192.168.1.100  mini-01  2h        │  │
│  │  remote-desktop    Running  192.168.1.101  studio-1 1d        │  │
│  └───────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- Mac nodes cannot run containers (no OCI runtime on macOS). Each Mac runs
  `spook serve` as a native LaunchDaemon.
- The controller runs on Linux and reaches Mac nodes over HTTP.
- VMs are declared as `MacOSVM` custom resources and managed with `kubectl`.
- The controller handles scheduling, cloning, provisioning, and status updates.

## Prerequisites

1. **Kubernetes cluster** (v1.24+) with at least one Linux node for the
   controller.

2. **Apple Silicon Mac(s)** with:
   - macOS 13+ (Ventura or later)
   - Spooktacular installed (`brew install spooktacular` or from source)
   - `spook serve` running as a LaunchDaemon
   - Network access from the K8s cluster to port 8484

3. **Base VM image** created on each Mac node:
   ```bash
   # On each Mac node:
   spook create macos-15-base --restore-image latest
   ```

4. **Helm** v3.10+ (for chart installation)

## Quick Start

### 1. Set up Mac nodes

On each Apple Silicon Mac that will host VMs:

```bash
# Install Spooktacular
brew install spooktacular

# Create a base VM image
spook create macos-15-base --restore-image latest

# Start the API server (or install as a LaunchDaemon)
spook serve --host 0.0.0.0 --port 8484
```

To install as a persistent LaunchDaemon:

```bash
sudo spook install-daemon
```

### 2. Install the CRD

```bash
kubectl apply -f deploy/kubernetes/crds/macosvm-crd.yaml
```

Verify:
```bash
kubectl get crd macosvms.spooktacular.app
```

### 3. Install the Helm chart

```bash
helm install spooktacular deploy/kubernetes/helm/spooktacular \
  --namespace spooktacular-system \
  --create-namespace \
  --set macNodes[0].name=mac-mini-01 \
  --set macNodes[0].endpoint=https://192.168.1.50:8484
```

Or with a values file:

```bash
cat > my-values.yaml <<EOF
macNodes:
  - name: mac-mini-01
    endpoint: https://192.168.1.50:8484
    labels:
      spooktacular.app/pool: ci
  - name: mac-studio-01
    endpoint: https://192.168.1.51:8484
    labels:
      spooktacular.app/pool: desktop
      spooktacular.app/gpu: "true"

tls:
  enabled: true
  existingSecret: spooktacular-tls

controller:
  replicas: 2
  logLevel: info
EOF

helm install spooktacular deploy/kubernetes/helm/spooktacular \
  --namespace spooktacular-system \
  --create-namespace \
  -f my-values.yaml
```

### 4. Create your first VM

```bash
kubectl apply -f deploy/kubernetes/examples/github-runner.yaml
```

Watch it come up:

```bash
kubectl get mvm -w
```

Expected output:
```
NAME              PHASE      IP              NODE          AGE
ci-runner-macos   Pending                                  0s
ci-runner-macos   Creating                   mac-mini-01   5s
ci-runner-macos   Running    192.168.1.100   mac-mini-01   45s
```

## Usage

### List all VMs

```bash
kubectl get mvm
kubectl get mvm -o wide    # Show extra columns (source, cpu, memory)
kubectl get mvm -A          # All namespaces
```

### Describe a VM

```bash
kubectl describe mvm ci-runner-macos
```

### Delete a VM

```bash
kubectl delete mvm ci-runner-macos
```

The controller will stop the VM on the Mac node and clean up disk resources.

### Watch VM events

```bash
kubectl get events --field-selector involvedObject.kind=MacOSVM
```

## Examples

| File | Description |
|------|-------------|
| `examples/github-runner.yaml` | Persistent GitHub Actions self-hosted runner |
| `examples/remote-desktop.yaml` | Remote desktop VM with VNC access |
| `examples/ephemeral-pool.yaml` | Pool of 3 ephemeral CI runners |

## Helm Chart Reference

### Key Values

| Parameter | Default | Description |
|-----------|---------|-------------|
| `controller.replicas` | `1` | Controller replica count |
| `controller.image.repository` | `ghcr.io/spooktacular/controller` | Controller image |
| `controller.image.tag` | `appVersion` | Image tag |
| `controller.logLevel` | `info` | Log level |
| `controller.reconcileInterval` | `30` | Reconcile interval (seconds) |
| `controller.nodeTimeout` | `30` | HTTP timeout for node calls |
| `macNodes` | `[]` | List of Mac node endpoints |
| `tls.enabled` | `false` | Enable mTLS to nodes |
| `rbac.create` | `true` | Create RBAC resources |
| `serviceAccount.create` | `true` | Create ServiceAccount |
| `metrics.enabled` | `true` | Enable Prometheus metrics |
| `crds.install` | `true` | Install CRDs via Helm |
| `crds.keep` | `true` | Keep CRDs on uninstall |

### Upgrade

```bash
helm upgrade spooktacular deploy/kubernetes/helm/spooktacular \
  --namespace spooktacular-system \
  -f my-values.yaml
```

### Uninstall

```bash
helm uninstall spooktacular --namespace spooktacular-system
```

Note: CRDs are kept by default to prevent accidental VM data loss. To remove
them manually:

```bash
kubectl delete crd macosvms.spooktacular.app
```

## Security

- **mTLS**: Enable `tls.enabled=true` to encrypt and authenticate controller-
  to-node communication.
- **RBAC**: The controller uses a dedicated ServiceAccount with least-privilege
  permissions.
- **Secrets**: Runner tokens should be stored in Kubernetes Secrets and
  referenced via `secretRef`, not inlined in MacOSVM specs.
- **Network policy**: In production, restrict network access so only the
  controller can reach Mac node APIs on port 8484.

## Troubleshooting

### Controller not starting
```bash
kubectl logs -n spooktacular-system deploy/spooktacular-controller -f
```

### VM stuck in Pending
Check that Mac node endpoints are reachable:
```bash
kubectl get configmap -n spooktacular-system spooktacular-config -o yaml
curl -k https://<mac-node-ip>:8484/health
```

### VM stuck in Creating
Check events for the specific VM:
```bash
kubectl describe mvm <vm-name>
```

Common causes: base image not found on node, insufficient disk, SSH not
configured in base image.

### Node unreachable
Verify `spook serve` is running on the Mac:
```bash
ssh admin@<mac-node-ip> 'launchctl list | grep spooktacular'
```
