# Kubernetes Integration

Manage macOS virtual machines as Kubernetes resources using the MacOSVM custom resource definition.

## Overview

The Spooktacular Kubernetes operator lets you manage macOS VMs
declaratively with `kubectl`. The Swift controller watches
`MacOSVM` custom resources and reconciles them by calling the
Spooktacular HTTP API on your Mac nodes.

### Architecture

```
┌────────────────────────────────────────────┐
│  Kubernetes Cluster (Linux)                │
│                                            │
│  ┌──────────────────────────────────────┐  │
│  │  spook-controller (Deployment)       │  │
│  │  Watches MacOSVM CRDs               │  │
│  │  Calls HTTPS API on Mac nodes       │  │
│  └──────────┬──────────────┬────────────┘  │
└─────────────│──────────────│───────────────┘
              │ HTTPS :8484  │ HTTPS :8484
     ┌────────▼──────┐  ┌───▼───────────┐
     │  Mac Host 01  │  │  Mac Host 02  │
     │  spook serve  │  │  spook serve  │
     │  ┌────┐┌────┐ │  │  ┌────┐┌────┐ │
     │  │VM-1││VM-2│ │  │  │VM-3││VM-4│ │
     │  └────┘└────┘ │  │  └────┘└────┘ │
     └───────────────┘  └───────────────┘
```

The controller runs on a Linux node in your cluster. Mac nodes
run `spook serve` natively as a LaunchDaemon (not as a pod —
Mac nodes can't run OCI containers). Each Mac supports up to
2 concurrent VMs per Apple's EULA Section 2B(iii).

## Prerequisites

- A Kubernetes cluster (v1.26+) with `kubectl` access
- One or more Apple Silicon Macs running `spook serve --host 0.0.0.0 --tls-cert cert.pem --tls-key key.pem`
- Helm v3 for installing the operator
- A base VM on each Mac (created with `spook create base --from-ipsw latest`)

## Quick Start

### 1. Apply the CRD

```bash
kubectl apply -f deploy/kubernetes/crds/macosvm-crd.yaml
```

### 2. Install the Helm chart

```bash
helm install spooktacular deploy/kubernetes/helm/spooktacular/ \
  --namespace spooktacular-system \
  --create-namespace \
  --set macNodes[0].name=mac-01 \
  --set macNodes[0].host=10.0.1.50 \
  --set macNodes[0].port=8484
```

### 3. Create a VM

```yaml
apiVersion: spooktacular.app/v1alpha1
kind: MacOSVM
metadata:
  name: runner-01
  namespace: default
spec:
  sourceVM: base
  cpu: 4
  memoryInGigabytes: 8
  diskInGigabytes: 64
  network: nat
  ephemeral: false
  provisioning:
    mode: ssh
    script: |
      #!/bin/bash
      echo "Hello from Kubernetes!"
```

```bash
kubectl apply -f runner-01.yaml
kubectl get mvm -w
```

## MacOSVM CRD Reference

### Spec Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `sourceVM` | string | (required) | Base VM to clone from |
| `cpu` | integer | 4 | Virtual CPU cores |
| `memoryInGigabytes` | integer | 8 | RAM in GB |
| `diskInGigabytes` | integer | 64 | Disk size in GB |
| `network` | string | `nat` | `nat`, `isolated`, or `bridged:<interface>` |
| `ephemeral` | boolean | false | Delete VM when it stops |
| `template` | string | - | `github-runner`, `remote-desktop`, or `openclaw` |
| `provisioning.mode` | string | `ssh` | `ssh` or `disk-inject` |
| `provisioning.script` | string | - | Shell script to execute |
| `provisioning.user` | string | `admin` | SSH user |
| `nodeSelector` | object | - | Match Mac nodes by labels |

### Status Fields

| Field | Type | Description |
|---|---|---|
| `phase` | string | Pending, Cloning, Starting, Running, Stopping, Failed, Deleted |
| `ip` | string | Resolved VM IP address |
| `nodeName` | string | Mac host the VM is running on |
| `message` | string | Human-readable status message |
| `lastTransitionTime` | string | ISO 8601 timestamp |

### Printer Columns

```bash
kubectl get mvm
# NAME        PHASE     IP              NODE     AGE
# runner-01   Running   192.168.64.3    mac-01   5m
# runner-02   Running   192.168.64.4    mac-01   3m
```

## Examples

### GitHub Actions Runner

```yaml
apiVersion: spooktacular.app/v1alpha1
kind: MacOSVM
metadata:
  name: gha-runner-01
spec:
  sourceVM: base
  cpu: 4
  memoryInGigabytes: 8
  ephemeral: true
  template: github-runner
  provisioning:
    mode: ssh
    script: |
      #!/bin/bash
      cd /Users/admin
      curl -o actions-runner.tar.gz -L \
        https://github.com/actions/runner/releases/latest/download/actions-runner-osx-arm64-2.x.x.tar.gz
      tar xzf actions-runner.tar.gz
      ./config.sh --url https://github.com/your-org/repo \
        --token YOUR_TOKEN --ephemeral
      ./run.sh
```

See `deploy/kubernetes/examples/github-runner.yaml` for the full example.

### Remote Desktop

```yaml
apiVersion: spooktacular.app/v1alpha1
kind: MacOSVM
metadata:
  name: desktop-01
spec:
  sourceVM: base
  cpu: 8
  memoryInGigabytes: 16
  template: remote-desktop
  network: "bridged:en0"
```

See `deploy/kubernetes/examples/remote-desktop.yaml` for the full example.

### Ephemeral Runner Pool

Create multiple ephemeral runners using a multi-document YAML:

```bash
kubectl apply -f deploy/kubernetes/examples/ephemeral-pool.yaml
```

This creates 3 runners that auto-destroy after each job completes.

## Controller Details

The Swift controller (`Sources/spook-controller/`) consists of:

- **KubernetesClient** — Reads service account credentials,
  makes authenticated requests to the K8s API
- **Reconciler** — List+watch pattern with auto-reconnection.
  Handles ADDED (clone+start), MODIFIED (retry/resolve IP),
  and DELETED (stop+delete) events
- **NodeManager** — Discovers Mac nodes by label, maps to
  HTTP API endpoints, periodic health checks
- **MacOSVMResource** — Codable types matching the CRD schema

The controller is stateless — all state lives in CRD status
fields and on the Mac nodes themselves.

## Mac Node Setup

Each Mac node must run `spook serve`:

```bash
# Install Spooktacular
brew install --cask spooktacular

# Create a base VM
spook create base --from-ipsw latest

# Start the HTTPS API (bind to all interfaces for cluster access)
spook serve --host 0.0.0.0 --port 8484 \
  --tls-cert /etc/spooktacular/tls/cert.pem \
  --tls-key /etc/spooktacular/tls/key.pem

# Or install as a service for persistence
sudo spook service install base  # for the base VM
```

Label Mac nodes in Kubernetes for the controller to discover:

```bash
kubectl label node mac-01 spooktacular.app/role=mac-host
```

## Troubleshooting

### VM stuck in Pending

No Mac node has available capacity. Each Mac supports max 2 VMs.
Check node status:

```bash
kubectl logs -n spooktacular-system deployment/spooktacular-operator
```

### Connection refused to Mac node

Verify `spook serve` is running and the port is reachable:

```bash
curl -k https://10.0.1.50:8484/health
```

### Provisioning failed

Check the VM events:

```bash
kubectl describe mvm runner-01
```

Common causes: SSH not enabled in the base VM, wrong
provisioning mode, script errors.

## Topics

### Related Guides

- <doc:GettingStarted>
- <doc:GitHubActionsGuide>
- <doc:JenkinsGuide>

### Key Types

- ``VirtualMachineSpecification``
- ``NetworkMode``
- ``ProvisioningMode``
