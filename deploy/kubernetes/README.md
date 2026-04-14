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
- The controller runs on Linux and reaches Mac nodes over HTTPS (TLS required by default).
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

# Start the API server with TLS (or install as a LaunchDaemon)
spook serve --host 0.0.0.0 --port 8484 \
  --tls-cert /etc/spooktacular/tls/cert.pem \
  --tls-key /etc/spooktacular/tls/key.pem
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

## Runner Pools

Runner pools are the recommended way to manage CI/CD runners. A `RunnerPool`
declaratively specifies a pool of runner VMs, the CI system they connect to,
and how they are recycled between jobs.

The RunnerPool reconciler implements a full lifecycle state machine with 9
states: `idle`, `provisioning`, `registering`, `ready`, `busy`, `completing`,
`recycling`, `draining`, and `terminated`. Each runner VM transitions through
these states automatically. The reconciler watches the actual state of each VM
and drives it toward the desired state declared in the `RunnerPool` spec,
handling failures, timeouts, and scale events at each transition.

```bash
# Install the RunnerPool CRD
kubectl apply -f deploy/kubernetes/crds/runnerpool-crd.yaml

# Create a GitHub Actions runner pool (2 ephemeral runners)
kubectl create secret generic github-runner-token \
  --from-literal=token=ghp_xxxxxxxxxxxxxxxxxxxx
kubectl apply -f deploy/kubernetes/examples/github-runner-pool.yaml

# Watch the pool scale up
kubectl get rp -w
# NAME              READY  BUSY  MIN  MAX  MODE       PHASE    AGE
# ios-ci-runners    2      0     2    4    ephemeral  Healthy  30s
```

Three lifecycle modes:
- **ephemeral** — Fresh APFS clone per job, destroy after completion. Clean state guaranteed.
- **warm-pool** — Pre-booted VMs returned to pool after scrub. Faster startup.
- **persistent** — Long-lived runners for systems like Jenkins that manage their own isolation.

Three CI integrations:
- **GitHub Actions** — Ephemeral runners with auto-registration and `--ephemeral` flag.
- **CircleCI** — Machine Runner 3.0 bound to a resource class.
- **Jenkins** — SSH-based agents following CloudBees best practices.

## Webhook Integration

The controller can receive GitHub webhooks for real-time job detection instead
of relying solely on polling. This reduces runner startup latency from the
reconcile interval (default 30s) to near-instant.

### Setup

1. **Create a webhook secret** in your cluster:

   ```bash
   kubectl create secret generic github-webhook-secret \
     --namespace spooktacular-system \
     --from-literal=secret=your-webhook-secret-here
   ```

2. **Enable the webhook receiver** in Helm values:

   ```yaml
   webhook:
     enabled: true
     secretRef:
       name: github-webhook-secret
       key: secret
     port: 8080
   ```

3. **Configure the webhook in GitHub** (repo or org settings):
   - Payload URL: `https://<controller-ingress>/webhook`
   - Content type: `application/json`
   - Secret: the same value from step 1
   - Events: select **Workflow jobs** only

The controller verifies every incoming webhook using HMAC-SHA256 and processes
only `workflow_job` events with action `queued`. Other event types are
acknowledged but ignored.

## Drain Mode

Before removing a Mac node from the cluster (e.g., for maintenance or to meet
EC2's 24-hour minimum allocation window), you should drain it to avoid
interrupting running jobs.

### Draining a node

```bash
# Mark the node as unschedulable (no new VMs will be placed on it)
kubectl label macnode mac-mini-01 spooktacular.app/drain=true

# Wait for running VMs to complete their current jobs
kubectl get mvm --field-selector spec.nodeName=mac-mini-01 -w
```

The controller will:

1. Stop scheduling new VMs to the drained node.
2. Allow in-progress jobs to complete (up to the configured drain timeout).
3. Transition idle runners on the node to the `draining` state.
4. Once all VMs are stopped, the node can be safely removed.

### Resuming a node

```bash
kubectl label macnode mac-mini-01 spooktacular.app/drain-
```

Removing the drain label makes the node schedulable again.

## Examples

| File | Description |
|------|-------------|
| `examples/github-runner.yaml` | Persistent GitHub Actions self-hosted runner (single VM) |
| `examples/github-runner-pool.yaml` | **Ephemeral GitHub runner pool (recommended)** |
| `examples/circleci-runner-pool.yaml` | CircleCI Machine Runner 3.0 pool |
| `examples/jenkins-runner-pool.yaml` | Jenkins SSH agent pool |
| `examples/remote-desktop.yaml` | Remote desktop VM with VNC access |
| `examples/ephemeral-pool.yaml` | Legacy: pool of 3 ephemeral runners (use RunnerPool instead) |

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
| `tls.enabled` | `true` | Enable TLS to nodes (strongly recommended) |
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
