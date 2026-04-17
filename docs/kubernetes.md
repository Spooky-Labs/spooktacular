# Spooktacular Kubernetes Integration

> **Status:** Shipping. The controller runs today, reconciles `MacOSVM` and
> `RunnerPool` custom resources, and is the primary integration path for
> EC2 Mac CI fleets. For single-host use, the `spook` CLI still works
> standalone.

Run macOS virtual machines as Kubernetes resources. Each Mac host
adds 2 VM pods to your cluster (Apple's kernel limit).

## Quick Start

```bash
# 1. Install Spooktacular on each Mac (EC2 Mac, Mac mini, etc.)
brew install --cask spooktacular
sudo spook service install --bind 0.0.0.0:9470

# 2. Install CRDs and the operator in your K8s cluster.
#    CRDs ship inside the repo at deploy/kubernetes/crds/. For offline or
#    pinned deployments, apply them directly from a checkout:
kubectl apply -f deploy/kubernetes/crds/macosvm-crd.yaml
kubectl apply -f deploy/kubernetes/crds/runnerpool-crd.yaml

helm install spooktacular ./deploy/kubernetes/helm/spooktacular \
  --namespace spooktacular-system --create-namespace \
  --set tls.certManager.enabled=true \
  --set admissionWebhook.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.prometheusRule.enabled=true

# 3. Create a VM
kubectl apply -f vm.yaml
```

> Earlier drafts of this doc linked `https://spooktacular.dev/k8s/crds/macosvm.yaml`.
> That URL was a placeholder and never published; always reference CRDs from
> `deploy/kubernetes/crds/` in the repo checkout or from your internal doc
> site pipeline.

## Custom Resources

### MacOSVM

A single macOS virtual machine.

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVM
metadata:
  name: ci-runner-01
  namespace: ci
spec:
  # Image source (required — choose one):
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2   # OCI image
  # fromIPSW: latest                                    # or IPSW

  # Hardware resources:
  resources:
    cpu: 4           # cores (minimum 4)
    memory: 8Gi      # RAM
    disk: 64Gi       # disk image size (APFS sparse)

  # Display:
  displays: 1        # 1 or 2 virtual displays

  # Network:
  network:
    mode: nat        # nat | bridged | isolated | host-only
    # interface: en0 # required for bridged mode

  # Shared folders:
  sharedFolders:
    - hostPath: /data/training
      guestTag: training-data
      readOnly: true

  # User-data provisioning:
  provisioning:
    mode: disk-inject   # see "Provisioning Modes" below
    userData: |
      #!/bin/bash
      echo "Hello from first boot!"
      # Install tools, configure runners, etc.
    sshUser: admin           # for mode: ssh
    sshKeySecret: ssh-key    # K8s Secret name, for mode: ssh

  # Node placement:
  node: mac-mini-01          # pin to specific Mac (optional)

status:
  phase: Running             # Pending | Creating | Installing | Provisioning | Running | Stopped | Failed
  ip: 192.168.64.3
  node: mac-mini-01
  conditions:
    - type: Ready
      status: "True"
```

### MacOSVMPool

A managed pool of ephemeral VMs with auto-replacement.

```yaml
apiVersion: spooktacular.io/v1alpha1
kind: MacOSVMPool
metadata:
  name: ci-runners
spec:
  replicas: 2                # VMs per host (max 2)
  image: ghcr.io/spooktacular/macos-xcode:15.4-16.2

  template: github-runner    # built-in template
  templateArgs:
    repo: myorg/myrepo
    token: ghp_xxxxxxxxxxxx
    labels: macos,arm64,xcode16

  ephemeral: true            # destroy + recreate after each job

  provisioning:
    mode: agent              # recommended for OCI images
    userData: ""             # template handles the script

  scaling:
    minReplicas: 0
    maxReplicas: 2           # per host (kernel limit)
    idleTimeout: 5m          # scale down after 5 min idle
```

## Provisioning Modes

When you specify `provisioning.userData`, you must choose how
Spooktacular executes the script inside the VM. The modes are
identical across `kubectl`, the `spook` CLI, and the GUI.

### `disk-inject` — Zero-Touch Provisioning

```yaml
provisioning:
  mode: disk-inject
  userData: |
    #!/bin/bash
    echo "Runs on first boot, no setup required"
```

Your script runs automatically when macOS starts. Before the VM
boots, Spooktacular writes a standard macOS LaunchDaemon to the
guest's disk that executes your script at startup.

**Works with:** Any macOS image, including vanilla IPSW installs.
No SSH, no agent, no network required.

**Best for:** Fresh VMs from IPSW, CI runners, zero-touch fleet
provisioning.

### `ssh` — SSH Execution

```yaml
provisioning:
  mode: ssh
  sshUser: admin
  sshKeySecret: my-ssh-key   # K8s Secret with private key
  userData: |
    #!/bin/bash
    echo "Runs via SSH after boot"
```

Spooktacular waits for the VM to boot, discovers its IP, connects
via SSH, and runs your script. Real-time output streaming.

**Works with:** VMs where Remote Login (SSH) is enabled in the
guest. Typically cloned from a base image with SSH configured.

**Best for:** Development workflows, debugging, interactive use.

### `agent` — Guest Agent (vsock)

```yaml
provisioning:
  mode: agent
  userData: |
    #!/bin/bash
    echo "Runs via guest agent, no network needed"
```

The Spooktacular guest agent runs inside the VM and communicates
with the host over a VirtIO socket — a direct channel that works
without any networking. Fastest provisioning mode.

**Works with:** VMs from Spooktacular's OCI images
(`ghcr.io/spooktacular/`), which include the agent.

**Best for:** CI/CD runners, ML workloads, isolated builds.

### `shared-folder` — Shared Folder Delivery

```yaml
provisioning:
  mode: shared-folder
  userData: |
    #!/bin/bash
    echo "Delivered via shared folder, run by watcher"
```

The script is placed on a VirtIO shared folder. A watcher daemon
in the guest detects and executes it. No networking required.

**Works with:** VMs that have the shared-folder watcher installed
(included in Spooktacular OCI images).

**Best for:** Environments where you can't modify the guest disk
and SSH isn't available.

## EC2 Mac Setup

Double your CI capacity on AWS EC2 Mac dedicated hosts.

```bash
# One-liner setup on an EC2 Mac:
curl -sSL https://spooktacular.dev/ec2-setup.sh | bash -s -- \
  --github-repo myorg/myrepo \
  --github-token ghp_xxx \
  --xcode 16.2

# Result: 2 GitHub Actions runners on one EC2 Mac.
# Before: 1 EC2 Mac = 1 runner. After: 1 EC2 Mac = 2 runners.
```

### Scaling

| EC2 Macs | Runners (before) | Runners (after) | Cost savings |
|----------|------------------|-----------------|--------------|
| 5        | 5                | 10              | 50%          |
| 10       | 10               | 20              | 50%          |
| 20       | 20               | 40              | 50%          |

## Node Configuration

Each Mac running Spooktacular is a "node" in the operator's
registry. Configure via Helm values or a ConfigMap:

```yaml
# values.yaml
nodes:
  - host: 10.0.1.50:9470
    token: <api-token>
    labels:
      xcode: "16.2"
      chip: "m2-pro"
  - host: 10.0.1.51:9470
    token: <api-token>
    labels:
      xcode: "16.2"
      chip: "m4"
```

The operator schedules VMs onto nodes respecting the 2-VM kernel
limit. Use `spec.node` to pin a VM to a specific Mac, or let the
scheduler choose (round-robin, capacity-aware).

## Controller Deployment

Two supported paths: the Helm chart (recommended) or raw `kubectl
apply` of the rendered manifests.

### Helm install

The chart at `deploy/kubernetes/helm/spooktacular` installs the
controller Deployment, ServiceAccount + ClusterRole + Binding,
NetworkPolicy, PodDisruptionBudget, ServiceMonitor, PrometheusRule,
and the `ValidatingWebhookConfiguration`.

```bash
# 1. Prerequisites (cluster-level).
#    - cert-manager >= 1.14 for automatic mTLS cert issuance.
#    - Prometheus Operator if using ServiceMonitor / PrometheusRule.
kubectl create namespace spooktacular-system

# 2. Install CRDs (not managed by Helm, so they persist across
#    release uninstalls).
kubectl apply -f deploy/kubernetes/crds/

# 3. Install the controller.
helm install spooktacular ./deploy/kubernetes/helm/spooktacular \
  --namespace spooktacular-system \
  --set tls.certManager.enabled=true \
  --set admissionWebhook.enabled=true \
  --set metrics.serviceMonitor.enabled=true \
  --set metrics.prometheusRule.enabled=true \
  --set networkPolicy.enabled=true \
  --set podDisruptionBudget.enabled=true \
  --set controller.replicas=2
```

Full values reference:

```yaml
# values.yaml
controller:
  replicas: 2            # pairs with PDB for HA
  resources:
    requests: { cpu: 500m, memory: 256Mi }
    limits:   { cpu: "2",  memory: 1Gi }
  leaderElection:
    enabled: true

tls:
  enabled: true
  certManager:
    enabled: true         # issues controller + webhook serving certs

admissionWebhook:
  enabled: true
  failurePolicy: Fail     # reject on webhook outage (fail closed)
  timeoutSeconds: 5

metrics:
  enabled: true
  serviceMonitor:
    enabled: true
  prometheusRule:
    enabled: true
    tlsExpirySecondsThreshold: 604800  # alert < 7 days
  grafana:
    enabled: true

networkPolicy:
  enabled: true
  macNodeCIDR: "10.0.0.0/16"          # tighten to your Mac subnet

podDisruptionBudget:
  enabled: true
  minAvailable: 1
```

Environment variables recognised by the controller (set via the
chart's `extraEnv` or mount into the Deployment manually):

| Variable                     | Purpose                                            |
|------------------------------|----------------------------------------------------|
| `SPOOK_TLS_CERT_PATH`        | Client cert for mTLS to Mac nodes                  |
| `SPOOK_TLS_KEY_PATH`         | Private key for mTLS                               |
| `SPOOK_TLS_CA_PATH`          | CA bundle pinning Mac node server certs            |
| `SPOOK_TENANCY_MODE`         | `single-tenant` (default) or `multi-tenant`        |
| `SPOOK_TENANT_CONFIG`        | Path to JSON tenant-pool mapping                   |
| `SPOOK_AUDIT_FILE`           | JSONL audit sink path (for SIEM forwarder)         |
| `SPOOK_AUDIT_IMMUTABLE_PATH` | Append-only audit store path                       |
| `SPOOK_AUDIT_MERKLE`         | Set `1` to enable tamper-evident Merkle audit tree |
| `SPOOK_IDP_CONFIG`           | OIDC / SAML provider registry JSON                 |
| `SPOOK_RBAC_CONFIG`          | RBAC role store (resource-level authorization)     |
| `SPOOK_SCHEDULER_POLICY`     | Fair-share scheduler policy JSON                   |
| `SPOOK_FLEET_CAPACITY`       | Total fleet VM slots (hostCount × 2 on Mac)        |

### DynamoDB distributed locking

When running multiple controllers across clusters — e.g., to serve a
single GitHub organization from multiple regions — point the leader
election at DynamoDB:

```yaml
controller:
  leaderElection:
    enabled: true
    backend: dynamodb
    dynamodb:
      tableName: spooktacular-locks
      region: us-east-1
```

### Raw kubectl alternative

For clusters without Helm, render the chart once and commit the output:

```bash
helm template spooktacular ./deploy/kubernetes/helm/spooktacular \
  --namespace spooktacular-system \
  --set tls.certManager.enabled=true \
  --set admissionWebhook.enabled=true \
  > manifests.yaml

kubectl apply -f manifests.yaml
```

Minimum manual manifests (ServiceAccount + ClusterRoleBinding +
Deployment + Service + mTLS Secret) are illustrated below:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: spooktacular-controller
  namespace: spooktacular-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: spooktacular-controller
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: spooktacular-controller   # installed by the chart above
subjects:
  - kind: ServiceAccount
    name: spooktacular-controller
    namespace: spooktacular-system
---
apiVersion: v1
kind: Secret
metadata:
  name: spooktacular-controller-tls
  namespace: spooktacular-system
type: kubernetes.io/tls
data:
  tls.crt: <base64 client cert>
  tls.key: <base64 private key>
  ca.crt:  <base64 pinning CA>
```
