# Kubernetes Integration

Manage macOS virtual machines as Kubernetes resources with custom CRDs and an operator.

## Overview

The Spooktacular Kubernetes operator bridges your Kubernetes cluster
with Apple Silicon Mac hosts running Spooktacular. You define macOS
VMs as Kubernetes resources, and the operator handles creation,
scheduling, provisioning, health checking, and cleanup.

### Architecture

```
┌─────────────────────────────────────────────┐
│  Kubernetes Cluster                         │
│                                             │
│  ┌─────────────────┐  ┌─────────────────┐  │
│  │  MacOSVM CRD    │  │  MacOSVMPool    │  │
│  │  ci-runner-01   │  │  ci-runners     │  │
│  └────────┬────────┘  └────────┬────────┘  │
│           │                    │            │
│  ┌────────▼────────────────────▼────────┐  │
│  │  Spooktacular Operator               │  │
│  │  (Deployment in cluster)             │  │
│  └────────┬─────────────────┬───────────┘  │
└───────────│─────────────────│──────────────┘
            │ HTTPS :9470     │ HTTPS :9470
   ┌────────▼──────┐  ┌──────▼────────┐
   │  Mac Host 01  │  │  Mac Host 02  │
   │  Spooktacular │  │  Spooktacular │
   │  ┌────┐┌────┐ │  │  ┌────┐┌────┐ │
   │  │VM-1││VM-2│ │  │  │VM-3││VM-4│ │
   │  └────┘└────┘ │  │  └────┘└────┘ │
   └───────────────┘  └───────────────┘
```

The operator runs as a standard Kubernetes Deployment. It communicates
with each Mac host over the Spooktacular control API (port 9470,
bearer token authenticated). Each Mac host supports a maximum of
**2 concurrent VMs** (Apple's kernel limit).

### Prerequisites

- A Kubernetes cluster (v1.26+) with `kubectl` access
- One or more Apple Silicon Mac hosts running Spooktacular with the
  API exposed (see <doc:EC2MacDeployment> for EC2 Mac setup)
- Helm v3 for installing the operator
- API tokens for each Mac host

## Installing the Operator

### Apply CRDs

```bash
kubectl apply -f https://spooktacular.dev/k8s/crds/macosvm.yaml
kubectl apply -f https://spooktacular.dev/k8s/crds/macosvmpool.yaml
```

### Install via Helm

```bash
helm repo add spooktacular https://charts.spooktacular.dev
helm repo update

helm install spooktacular-operator spooktacular/operator \
    --namespace spooktacular-system \
    --create-namespace \
    --set nodes[0].host=10.0.1.50:9470 \
    --set nodes[0].token="$(ssh ec2-user@10.0.1.50 'cat ~/.spooktacular/api-token')" \
    --set nodes[1].host=10.0.1.51:9470 \
    --set nodes[1].token="$(ssh ec2-user@10.0.1.51 'cat ~/.spooktacular/api-token')"
```

### Node Configuration via values.yaml

For larger deployments, use a values file:

```yaml
# values.yaml
replicaCount: 2  # operator HA

nodes:
  - host: 10.0.1.50:9470
    token: <api-token-for-host-50>
    labels:
      xcode: "16.2"
      chip: "m2-pro"
      location: "us-east-1a"
  - host: 10.0.1.51:9470
    token: <api-token-for-host-51>
    labels:
      xcode: "16.2"
      chip: "m4"
      location: "us-east-1b"
  - host: 10.0.1.52:9470
    token: <api-token-for-host-52>
    labels:
      xcode: "15.4"
      chip: "m1"
      location: "us-east-1c"
```

```bash
helm install spooktacular-operator spooktacular/operator \
    --namespace spooktacular-system \
    --create-namespace \
    -f values.yaml
```

### Using a ConfigMap for Dynamic Node Registration

Instead of static Helm values, you can manage nodes via a ConfigMap
that the operator watches for changes:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: spooktacular-nodes
  namespace: spooktacular-system
data:
  nodes.yaml: |
    - host: 10.0.1.50:9470
      token: <token>
      labels:
        xcode: "16.2"
    - host: 10.0.1.51:9470
      token: <token>
      labels:
        xcode: "16.2"
```

## MacOSVM CRD Reference

A `MacOSVM` represents a single macOS virtual machine. The operator
creates and manages the VM on a Mac host.

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ci-runner-01
  namespace: ci
spec:
  # ─── Image Source (required — choose one) ───────────────
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2  # OCI image
  # fromIPSW: latest                                   # or IPSW

  # ─── Hardware Resources ─────────────────────────────────
  resources:
    cpu: 4            # Virtual CPU cores (minimum 4)
    memory: 8Gi       # RAM (must be >= host minimum)
    disk: 64Gi        # Disk image size (APFS sparse)

  # ─── Display Configuration ──────────────────────────────
  displays: 1         # Number of virtual displays (1 or 2)

  # ─── Network ────────────────────────────────────────────
  network:
    mode: nat         # nat | bridged | isolated | host-only
    # interface: en0  # Required only for bridged mode

  # ─── Shared Folders ─────────────────────────────────────
  sharedFolders:
    - hostPath: /data/training
      guestTag: training-data
      readOnly: true
    - hostPath: /data/output
      guestTag: output
      readOnly: false

  # ─── Provisioning ──────────────────────────────────────
  provisioning:
    mode: disk-inject          # disk-inject | ssh | agent | shared-folder
    userData: |
      #!/bin/bash
      echo "Hello from Kubernetes!"
    sshUser: admin             # For mode: ssh
    sshKeySecret: ssh-key      # K8s Secret name, for mode: ssh

  # ─── Node Placement ────────────────────────────────────
  node: mac-mini-01            # Pin to specific Mac (optional)
  nodeSelector:                # Or select by labels
    xcode: "16.2"
    chip: "m2-pro"

status:
  phase: Running               # Lifecycle phase (read-only)
  ip: 192.168.64.3             # Guest IP address
  node: mac-mini-01            # Assigned Mac host
  conditions:
    - type: Ready
      status: "True"
      lastTransitionTime: "2025-01-15T10:30:00Z"
    - type: Provisioned
      status: "True"
      lastTransitionTime: "2025-01-15T10:28:00Z"
```

### Field Reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `spec.image` | string | Yes (or `fromIPSW`) | - | OCI image reference |
| `spec.fromIPSW` | string | Yes (or `image`) | - | IPSW source (`latest` or path) |
| `spec.resources.cpu` | int | No | 4 | CPU cores (min 4, see ``VMSpec/minimumCPUCount``) |
| `spec.resources.memory` | string | No | 8Gi | RAM allocation |
| `spec.resources.disk` | string | No | 64Gi | Disk size (APFS sparse) |
| `spec.displays` | int | No | 1 | Virtual displays (1-2) |
| `spec.network.mode` | string | No | nat | ``NetworkMode`` value |
| `spec.network.interface` | string | No | - | Host interface for bridged mode |
| `spec.sharedFolders` | array | No | [] | ``SharedFolder`` specifications |
| `spec.provisioning.mode` | string | No | disk-inject | ``ProvisioningMode`` value |
| `spec.provisioning.userData` | string | No | - | Shell script to execute |
| `spec.provisioning.sshUser` | string | No | admin | SSH user for `ssh` mode |
| `spec.provisioning.sshKeySecret` | string | No | - | K8s Secret containing SSH key |
| `spec.node` | string | No | - | Pin to a named Mac host |
| `spec.nodeSelector` | map | No | - | Match hosts by labels |

### Status Phases

| Phase | Description |
|-------|-------------|
| `Pending` | Waiting for a Mac host with available capacity |
| `Creating` | VM bundle is being created on the host |
| `Installing` | macOS is being installed from IPSW (10-20 min) |
| `Provisioning` | User-data script is running |
| `Running` | VM is booted and healthy |
| `Stopped` | VM is cleanly shut down |
| `Failed` | An error occurred — check events for details |

These phases map to the ``VMState`` enum in SpooktacularKit.

## MacOSVMPool CRD Reference

A `MacOSVMPool` manages a pool of identical macOS VMs with
auto-replacement and optional ephemeral behavior.

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: ci-runners
  namespace: ci
spec:
  # ─── Pool Size ──────────────────────────────────────────
  replicas: 4                  # Total VMs across all hosts

  # ─── VM Template ────────────────────────────────────────
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2

  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi

  # ─── Built-in Templates ────────────────────────────────
  template: github-runner      # Predefined setup template
  templateArgs:
    repo: myorg/myrepo
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16

  # ─── Ephemeral Mode ────────────────────────────────────
  ephemeral: true              # Destroy and recreate after each job

  # ─── Provisioning ──────────────────────────────────────
  provisioning:
    mode: agent                # Recommended for OCI images
    userData: ""               # Template handles the script

  # ─── Scaling ────────────────────────────────────────────
  scaling:
    minReplicas: 0             # Scale to zero when idle
    maxReplicas: 4             # Maximum VMs (2 per host limit)
    idleTimeout: 5m            # Scale down after 5 min idle
    cooldownPeriod: 2m         # Wait between scaling decisions
```

### Pool Field Reference

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `spec.replicas` | int | Yes | - | Desired number of VMs |
| `spec.image` | string | Yes | - | OCI image for all pool VMs |
| `spec.resources` | object | No | 4cpu/8Gi/64Gi | Hardware resources |
| `spec.template` | string | No | - | Built-in template name |
| `spec.templateArgs` | map | No | - | Arguments for the template |
| `spec.ephemeral` | bool | No | false | Recreate VMs after each job |
| `spec.provisioning` | object | No | - | Provisioning configuration |
| `spec.scaling.minReplicas` | int | No | replicas | Minimum pool size |
| `spec.scaling.maxReplicas` | int | No | replicas | Maximum pool size |
| `spec.scaling.idleTimeout` | duration | No | - | Scale-down idle threshold |
| `spec.scaling.cooldownPeriod` | duration | No | 2m | Minimum time between scales |

## Scheduling

The operator schedules VMs onto Mac hosts using a capacity-aware
algorithm:

1. **Filter** — Exclude hosts that are full (2 VMs already running)
2. **Match labels** — If `spec.nodeSelector` is set, only consider
   hosts with matching labels
3. **Pin** — If `spec.node` is set, use that specific host
4. **Score** — Among eligible hosts, prefer the one with the most
   available capacity (fewest running VMs)
5. **Tie-break** — Round-robin across equally scored hosts

### Node Pinning

Pin a VM to a specific Mac host when you need:

- Access to specific hardware (GPU benchmarks, specific chip)
- Shared folders that only exist on one host
- Debugging a specific host

```yaml
spec:
  node: mac-mini-01
```

### Label-Based Affinity

Use `nodeSelector` to match hosts by their configured labels:

```yaml
spec:
  nodeSelector:
    xcode: "16.2"
    chip: "m2-pro"
```

This only schedules the VM onto hosts with both labels matching.

## Provisioning in Kubernetes

All four ``ProvisioningMode`` strategies work identically from
Kubernetes. See <doc:Provisioning> for detailed explanations of each.

### disk-inject (Recommended for IPSW)

```yaml
provisioning:
  mode: disk-inject
  userData: |
    #!/bin/bash
    echo "Zero-touch provisioning — works on vanilla macOS"
```

### agent (Recommended for OCI Images)

```yaml
provisioning:
  mode: agent
  userData: |
    #!/bin/bash
    echo "Fastest mode — uses VirtIO socket, no network needed"
```

### ssh

```yaml
provisioning:
  mode: ssh
  sshUser: admin
  sshKeySecret: my-ssh-key
  userData: |
    #!/bin/bash
    echo "Runs via SSH after boot"
```

The referenced Secret must contain the private key:

```bash
kubectl create secret generic my-ssh-key \
    --from-file=id_ed25519=~/.ssh/id_ed25519
```

### shared-folder

```yaml
provisioning:
  mode: shared-folder
  userData: |
    #!/bin/bash
    echo "Delivered via VirtIO shared folder"
```

## Example: GitHub Actions Runner Pool

A complete configuration for running ephemeral GitHub Actions runners
across multiple Mac hosts:

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: github-runners
  namespace: ci
spec:
  replicas: 6
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  resources:
    cpu: 4
    memory: 8Gi
    disk: 64Gi
  template: github-runner
  templateArgs:
    repo: myorg/myrepo
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16
  ephemeral: true
  provisioning:
    mode: agent
  scaling:
    minReplicas: 2
    maxReplicas: 6
    idleTimeout: 10m
```

This creates 6 runners spread across 3 Mac hosts (2 per host).
When runners are idle for 10 minutes, the pool scales down to 2.

See <doc:GitHubActionsGuide> for a comprehensive GitHub Actions
setup guide.

## Example: ML Training Job

A VM configured for machine learning with shared dataset access
and host-only networking:

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ml-trainer
  namespace: ml
spec:
  image: ghcr.io/spooktacular/macos-ml:15.4
  resources:
    cpu: 8
    memory: 16Gi
    disk: 100Gi
  network:
    mode: host-only
  sharedFolders:
    - hostPath: /data/training-sets
      guestTag: training-data
      readOnly: true
    - hostPath: /data/checkpoints
      guestTag: checkpoints
      readOnly: false
  provisioning:
    mode: agent
    userData: |
      #!/bin/bash
      cd /Volumes/training-data
      python3 train.py --output /Volumes/checkpoints/
```

See <doc:MLWorkloads> for detailed ML workflow documentation.

## Example: Remote Desktop VM

A VM configured for remote desktop access with a high-resolution
display:

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: design-review
  namespace: design
spec:
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2
  resources:
    cpu: 8
    memory: 16Gi
    disk: 100Gi
  displays: 2
  network:
    mode: bridged
    interface: en0
  provisioning:
    mode: disk-inject
    userData: |
      #!/bin/bash
      # Enable Screen Sharing for VNC access
      sudo launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist
      sudo defaults write /var/db/launchd.db/com.apple.launchd/overrides.plist \
          com.apple.screensharing -dict Disabled -bool false
```

See <doc:RemoteDesktop> for the full remote desktop guide.

## Monitoring

### Listing VMs

```bash
# List all MacOSVM resources across namespaces
kubectl get macosvm -A

# Output:
# NAMESPACE  NAME            IMAGE                                     CPU  MEM   STATUS
# ci         ci-runner-01    ghcr.io/spooktacular/macos-xcode:15.4    4    8Gi   Running
# ci         ci-runner-02    ghcr.io/spooktacular/macos-xcode:15.4    4    8Gi   Running
# ml         ml-trainer      ghcr.io/spooktacular/macos-ml:15.4       8    16Gi  Provisioning
```

### Describing a VM

```bash
kubectl describe macosvm ci-runner-01 -n ci

# Shows:
# - Full spec
# - Current status and conditions
# - Events (creation, provisioning, errors)
# - Assigned node
# - Guest IP address
```

### Events

```bash
# Watch events in real time
kubectl get events -n ci --field-selector involvedObject.kind=MacOSVM -w

# Example events:
# Scheduled    Successfully scheduled to node mac-host-01
# Creating     Creating VM bundle on mac-host-01
# Installing   Installing macOS from IPSW (this takes 10-20 minutes)
# Provisioning Running user-data script via disk-inject
# Running      VM is booted and ready
```

### Pool Status

```bash
kubectl get macosvmpool -n ci

# NAMESPACE  NAME             DESIRED  READY  AVAILABLE  AGE
# ci         github-runners   6        6      6          2d
```

## Scaling

### Manual Scaling

```bash
# Scale a pool up or down
kubectl scale macosvmpool github-runners -n ci --replicas=4
```

### Webhook-Driven Autoscaling

The operator includes a webhook receiver that can scale pools
based on external events (such as GitHub `workflow_job` webhooks):

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: github-runners
spec:
  replicas: 2
  scaling:
    minReplicas: 0
    maxReplicas: 8
    webhook:
      path: /webhook/github
      secret: github-webhook-secret
```

Configure your GitHub repository to send `workflow_job` events to
the operator's webhook endpoint. The operator scales the pool
based on queued and in-progress jobs.

### Cluster Autoscaler Integration

For EC2 Mac fleets, combine the Spooktacular operator with the
Kubernetes Cluster Autoscaler to dynamically add or remove Mac
hosts:

1. The Spooktacular operator detects that all hosts are at capacity
2. It creates a "pending" MacOSVM that cannot be scheduled
3. The Cluster Autoscaler detects the pending workload
4. It launches a new EC2 Mac dedicated host via the ASG
5. The new host runs the setup script and registers with the operator
6. The pending VM is scheduled to the new host

> Note: EC2 Mac hosts have a 24-hour minimum allocation. The Cluster
> Autoscaler should be configured with appropriate scale-down
> cooldowns.

## Troubleshooting

### Pending VMs

**Symptom:** A MacOSVM stays in `Pending` phase indefinitely.

**Cause:** No Mac host has available capacity (each host supports
a maximum of 2 VMs).

**Solution:**

```bash
# Check host capacity
kubectl describe configmap spooktacular-nodes -n spooktacular-system

# Check operator logs
kubectl logs -n spooktacular-system deployment/spooktacular-operator

# Add more hosts or free capacity by deleting unused VMs
kubectl delete macosvm unused-vm -n ci
```

### Capacity Errors

**Symptom:** Events show "insufficient capacity" errors.

**Cause:** The requested resources (CPU, memory) exceed what the
host can provide. Each Mac host has a fixed amount of CPU and RAM
that must be shared between the host OS and up to 2 VMs.

**Solution:** Reduce VM resource requests:

```yaml
resources:
  cpu: 4       # Not 8 — leaves room for the host and a second VM
  memory: 8Gi  # Not 16Gi on a 16 GB host
```

### Node Connectivity

**Symptom:** Operator logs show "connection refused" or "timeout"
errors for a Mac host.

**Cause:** The operator cannot reach the Spooktacular API on the
Mac host.

**Solution:**

```bash
# Verify connectivity from the operator pod
kubectl exec -n spooktacular-system deployment/spooktacular-operator -- \
    curl -s -H "Authorization: Bearer <token>" \
    http://10.0.1.50:9470/v1/health

# Check that Spooktacular is running on the Mac host
ssh ec2-user@10.0.1.50 'spook service status'

# Check security group rules
aws ec2 describe-security-groups --group-ids sg-0xxxx \
    --query 'SecurityGroups[].IpPermissions[]'
```

### Provisioning Failures

**Symptom:** VM enters `Failed` phase during provisioning.

**Cause:** The user-data script encountered an error, or the
provisioning mode is incompatible with the VM image.

**Solution:**

```bash
# Check events for error details
kubectl describe macosvm my-vm -n ci

# Common fixes:
# - disk-inject mode with an OCI image: switch to agent mode
# - ssh mode without SSH enabled: switch to disk-inject
# - agent mode without the agent installed: use disk-inject
```

See <doc:Provisioning> for guidance on choosing the right
``ProvisioningMode``.

## Topics

### Related Guides

- <doc:EC2MacDeployment>
- <doc:GitHubActionsGuide>
- <doc:Provisioning>
- <doc:MLWorkloads>
- <doc:RemoteDesktop>

### Key Types

- ``VMSpec``
- ``NetworkMode``
- ``ProvisioningMode``
- ``SharedFolder``
- ``VMState``
